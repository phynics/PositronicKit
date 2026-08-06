# PKARCH-003: Extract TimelineManager lifecycle seams

**Priority:** P2
**Type:** Internal refactor (public `TimelineManager` surface stays stable; new internal services are package-private)
**Depends on:** None
**Blocks:** PKARCH-002 (ToolRouter extraction; a stable workspace attachment seam makes the resolver easier to test)
**Triage:** done
**Status:** Done (2026-07-07, commit `01e871a`) — extracted `TimelineLifecycleService`, `WorkspaceAttachmentService`,
and `RuntimeToolPolicyFactory` behind a narrow internal `TimelineCache` seam; `TimelineManager`
is now a thin coordinator with byte-identical public surface. `ContextManager` promoted
`internal` → `package` to appear in cache-protocol signatures (invisible to external consumers).
20 new isolation tests across the three services (lifecycle, attachment, tool-policy factory);
existing `TimelineManagerTests`/`WorkspaceAttachmentTests` and the four `createToolManager`
policy tests migrated to `RuntimeToolPolicyFactoryTests`. `swift test` 833 tests / 152 suites
green; `make verify` and `make verify-products` green. No downstream references found.

**Superseded by PKDEEP-002-impl on 2026-07-08.** The `TimelineCache` protocol-with-one-adapter
and circular re-entry were found to be a hypothetical seam; the test-isolation justification was
hollow (the fake mirrored the actor's own dictionaries). `TimelineLifecycleService` and
`WorkspaceAttachmentService` are folded back into `TimelineManager` as extension files;
`RuntimeToolPolicyFactory` remains as the legitimate extraction.

### Summary

`TimelineManager` is a 627-line actor that combines timeline lifecycle management, workspace attachment/detachment, default runtime tool policy, `ContextManager` provisioning, and in-memory LRU caches. This ticket extracts three focused services behind the existing `TimelineManager` seam so each concern has its own module and test surface.

### Current Problem

- A caller that only wants to attach a workspace must still reason about the full 627-line module.
- `createTimeline`, `hydrateTimeline`, `attachWorkspace`, `detachWorkspace`, and `createToolManager` all live in one file with overlapping cache updates.
- The deletion test fails: deleting `TimelineManager` would scatter lifecycle, workspace attachment, tool policy, and cache eviction across the runtime.

### Implementation Requirements

1. Extract three internal services:
   - `TimelineLifecycleService` — owns `createTimeline`, `hydrateTimeline`, `updateTimelineTitle`, `deleteTimeline`, and `cleanupStaleTimelines`, plus the timeline cache.
   - `WorkspaceAttachmentService` — owns `attachWorkspace`, `detachWorkspace`, `getWorkspaces`, and `getWorkspace`, including primary-workspace normalization and the `missing` status check.
   - `RuntimeToolPolicyFactory` — owns `createToolManager` and the installation of filesystem, timeline-observation, and timeline-send tools based on `RuntimeToolPolicy`.
2. `TimelineManager` keeps its public interface and remains the coordinator/cache owner; it delegates to the services for behavior.
3. Preserve the existing cache eviction behavior in `evictTimelineFromMemory` and the prompt-history registry cleanup.
4. Keep the existing persistence protocols as the real seams; do not change public persistence interfaces.

### Acceptance Criteria

- [ ] `TimelineManager.swift` is reduced to a coordinator plus cache state; the three services live in their own files.
- [ ] `TimelineLifecycleService` tests cover create/hydrate/evict/cleanup without touching workspace attachment.
- [ ] `WorkspaceAttachmentService` tests cover attach/detach/primary resolution with in-memory persistence adapters.
- [ ] `RuntimeToolPolicyFactory` tests verify which tools are installed for each policy flag combination.
- [ ] Existing `TimelineManager` tests still pass; no behavioral regression.
- [ ] `make verify` green.
