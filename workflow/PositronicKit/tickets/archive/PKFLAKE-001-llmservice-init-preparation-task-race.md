# PKFLAKE-001 — Fix fire-and-forget `preparationTask` assignment race in `LLMService.init`

**Priority:** P1
**Type:** Bug (concurrency race)
**Depends on:** —
**Blocks:** —
**Triage:** ready-for-agent
**Status:** Done — implemented via `PreparationTaskBox`; preparation task assigned synchronously in init; regression tests added. Merged `b873f9a`; `make verify` green (896 tests / 156 suites).

### Summary

Both storage-based `LLMService` init overloads assign the preparation task via an
un-awaited `Task { await self.setPreparationTask(t) }`. Between init returning and that
task executing on the actor, callers observe `preparationTask == nil`; under load the
configuration-load task can complete before `setPreparationTask` runs, leaving
`preparationTask` permanently `nil`. This races on every construction that does not pass
a pre-built client.

### Current Problem

`Sources/PositronicKit/Services/LLM/LLMService.swift:131` and `:159`:

```swift
self.preparationTask = nil
let t = Task { [needsLoad] in ... }
Task { await self.setPreparationTask(t) }   // fire-and-forget, not awaited
```

Any code path that awaits `preparationTask` to ensure configuration is loaded can see
`nil` and proceed against an unconfigured service — nondeterministic startup behavior.

### Implementation Requirements

1. Remove the fire-and-forget hop. Options (pick the simplest that compiles under
   Swift 6 actor-init rules):
   - Store the preparation work in a `let` property assigned directly in init
     (e.g. lazily started on first access via an async accessor), or
   - Assign `self.preparationTask = Task { ... }` directly in init if isolation allows
     (the task must not capture `self` before init completes — capture the needed
     dependencies explicitly, as the current code already does with `[needsLoad]`).
2. Ensure every public entry point that requires configuration awaits the preparation
   work deterministically (no window where it is observably `nil` after init).
3. Add a regression test: construct `LLMService` with a storage that delays load, and
   assert the first call awaits configuration rather than seeing an unconfigured service.

### Acceptance Criteria

- [ ] No un-awaited `Task { await self.setPreparationTask(...) }` remains.
- [ ] Regression test proves callers cannot observe a nil/unset preparation task after init.
- [ ] `make verify` green.
- [ ] No public API change (or CHANGELOG note if init signatures move).
