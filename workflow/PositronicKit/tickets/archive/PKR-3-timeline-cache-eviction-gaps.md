# PKR-3 — In-memory timeline cache eviction gaps: dead sweep + agent deletion doesn't cascade

**Status:** Done
**Severity:** 🟠 Medium (per-timeline memory leaks in long-running processes)
**Repos:** PositronicKit (+ Monad wiring)
**Source:** PositronicKit review 2026-07-02

## Problem

Two related eviction gaps around `TimelineManager`'s in-memory caches
(`timelines`/`contextManagers`/`toolManagers`):

1. **`cleanupStaleTimelines(maxAge:)` is dead code** (`TimelineManager.swift:302-311`): the stale
   sweep has zero callers across PositronicKit/Monad/Shuttle — no timer, no lifecycle service.
   Timelines hydrated but never explicitly deleted leak for the process lifetime.
2. **`AgentInstanceManager.deleteInstance` doesn't evict** (`AgentInstanceManager.swift:253-288`):
   it deletes the private timeline from the *store* (`timelineStore.deleteTimeline`) but never
   calls `TimelineManager.deleteTimeline(id:)` (the cache eviction at `TimelineManager.swift:295-299`),
   unlike `TimelineAPIController.delete` (Monad, `TimelineAPIController.swift:171-174`) which does
   both. Orphaned managers (plus the `TimelinePromptHistoryRegistry` entry — see JRN-2) stay
   retained forever.

## Suggested direction

Route deletion through a single "delete timeline everywhere" seam (manager + store + prompt-history
registry) and use it from both the API controller and `AgentInstanceManager`. For the sweep: wire
`cleanupStaleTimelines` into a `ServiceLifecycle` maintenance task or delete it. Overlaps JRN-2 —
consider fixing together.

## Resolution (2026-07-04)

### `TimelineManager.deleteTimeline(id:)` — runtime-eviction seam

Injected `TimelinePromptHistoryRegistry?` into `TimelineManager` (optional, default nil).
`deleteTimeline(id:)` (now `async`) evicts the in-memory caches (timelines/contextManagers/
toolManagers) AND the prompt-history registry entry via a shared internal `evictTimelineFromMemory`.
It does not delete from the store — persistence deletion remains a separate caller concern
(`timelineStore.deleteTimeline`), preserving the existing two-call cache+store pattern used by
`TimelineAPIController.delete` (which now gets registry eviction for free). `cleanupStaleTimelines`
(now `async`) shares the same `evictTimelineFromMemory` so the stale sweep also drops prompt-history
entries instead of orphaning them.

### `AgentInstanceManager.deleteInstance` — wired to the seam

`AgentInstanceManager` gained an optional `TimelineManager?` dependency. In `deleteInstance`, when a
`TimelineManager` is injected, it calls `timelineManager.deleteTimeline(id: privateTimelineId)` to
evict caches + registry before the existing `timelineStore.deleteTimeline` deletes the persisted row.
When no `TimelineManager` is injected (e.g. unit tests not exercising eviction), falls back to the
store-only path. `MonadServerFactory` reconstructs the `AgentInstanceManager` after the
`PositronicKit` facade is built so `coreChat.timelineManager` can be injected.

### Sweep

`cleanupStaleTimelines` kept as a public opt-in maintenance utility (it has a unit test, and the
JRN-2 LRU cap is the unconditional safety net on the registry). Not auto-wired into a
`ServiceLifecycle` task — that's a host concern; the method is available for hosts that want a
time-based sweep on top of the unconditional explicit-deletion + LRU-cap defenses.

### Tests (PositronicKit)

- `deleteTimeline(id:)` evicts the prompt-history registry entry (state resets on re-fetch).
- `cleanupStaleTimelines(maxAge:)` also drops the prompt-history registry entry.
- `deleteTimeline(id:)` with no injected registry still evicts the cache.
- `AgentInstanceManager.deleteInstance` with an injected `TimelineManager` evicts both the cache
  and the registry entry for the private timeline.

680 PositronicKit tests + 172 Monad tests green.
