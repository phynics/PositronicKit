# PKDEEP-002-impl — Collapse the circular TimelineCache seam back into TimelineManager

**Priority:** P2
**Type:** Implementation (deepening, promoted from PKDEEP-002 research; supersedes PKARCH-003)
**Depends on:** PKDEEP-002 (research)
**Blocks:** PKDEEP-007
**Triage:** done
**Status:** Done (2026-07-08, commit `6c71c60`) — collapsed `TimelineLifecycleService` and
`WorkspaceAttachmentService` back into `TimelineManager` as `private extension` files
(`TimelineManager+Lifecycle.swift`, `TimelineManager+Attachments.swift`). Deleted `TimelineCache.swift`
(protocol + conformance, 97 lines), `TimelineLifecycleService.swift` (248 lines),
`WorkspaceAttachmentService.swift` (128 lines), `FakeTimelineCache.swift` (40 lines),
`TimelineLifecycleServiceTests.swift` (198 lines), `WorkspaceAttachmentServiceTests.swift` (191 lines).
All `await cache.cacheX()` hops collapsed to synchronous in-actor dict access. `ContextManager`
reverted from `package` to `internal`. `RuntimeToolPolicyFactory` preserved unchanged. 7 unique
test cases ported to actor-level suites (`TimelineManagerTests` +6, `WorkspaceAttachmentTests` +1).
`make verify` green (885 tests / 155 suites). Net -550 lines. Public API byte-identical. PKARCH-003
superseded.

### Summary

Collapse the `TimelineLifecycleService` and `WorkspaceAttachmentService` structs back into
`TimelineManager`, retire the 9-method `TimelineCache` protocol (one production conformer =
hypothetical seam), and delete the test fake. The circular re-entry
(`Manager → Service → Manager-via-protocol`) collapses to synchronous in-actor dict access.
`RuntimeToolPolicyFactory` stays. Public API byte-identical. See PKDEEP-002 for the full research.

### Implementation

1. **Create `TimelineManager+Lifecycle.swift`** — move `createTimeline`, `hydrateTimeline`,
   `updateTimelineTitle`, `deleteTimeline`, `cleanupStaleTimelines`, `evictTimelineFromMemory`,
   `setupTimelineComponents`, `writeDefaultNotes` from `TimelineLifecycleService` into a
   `private extension TimelineManager`. All `await cache.cacheX(...)` calls become direct dict
   access: `timelines[id] = timeline`, `toolManagers[id] = toolManager`, etc.
2. **Create `TimelineManager+Attachments.swift`** — move `attachWorkspace`, `detachWorkspace`,
   `getWorkspaces`, `getWorkspace`, `normalizeWorkspaceStatus` from `WorkspaceAttachmentService`
   into a `private extension TimelineManager`. Same cache→direct-access transformation.
3. **Modify `TimelineManager.swift`** — delete the `lifecycleService`/`attachmentService` computed
   properties (lines 153-180). The public forwarding extensions (lines 217-326) become direct
   implementations (signatures unchanged). `ContextManager` can revert `package` → `internal`
   (it was promoted only for the protocol signature).
4. **Delete `TimelineCache.swift`** (97 lines) — protocol + conformance, retired.
5. **Delete `TimelineLifecycleService.swift`** (248 lines) — methods folded into the actor.
6. **Delete `WorkspaceAttachmentService.swift`** (128 lines) — methods folded into the actor.
7. **Preserve `RuntimeToolPolicyFactory.swift`** (64 lines) — pure helper, stays as-is.

### Test changes

- **Delete** `Tests/PositronicKitTests/Services/FakeTimelineCache.swift` (39 lines).
- **Delete** `Tests/PositronicKitTests/Services/TimelineLifecycleServiceTests.swift` (197 lines) →
  port unique cases (`hydrateShortCircuit`, `hydrateMissing`, `updateTitleMissing`,
  `cleanupStaleDoesNotPersistDelete`, `writeDefaultNotes`) into `TimelineManagerTests.swift` or a
  new `TimelineManagerLifecycleTests.swift` (~150-180 lines, actor + `MockPersistenceService`).
- **Delete** `Tests/PositronicKitTests/Services/WorkspaceAttachmentServiceTests.swift` (190 lines) →
  port unique cases (attach-uncached-resolves-from-persistence, noToolManager-no-op) into
  `WorkspaceAttachmentTests.swift` (~20-30 lines).
- **Preserve** `RuntimeToolPolicyFactoryTests.swift` (175 lines).
- **Preserve** `TimelineManagerTests.swift` (140 lines, extend).
- **Preserve** `WorkspaceAttachmentTests.swift` (422 lines, extend).

### Acceptance criteria

- [ ] `TimelineCache.swift`, `TimelineLifecycleService.swift`, `WorkspaceAttachmentService.swift` deleted.
- [ ] `FakeTimelineCache.swift`, `TimelineLifecycleServiceTests.swift`, `WorkspaceAttachmentServiceTests.swift` deleted.
- [ ] `TimelineManager+Lifecycle.swift` and `TimelineManager+Attachments.swift` created.
- [ ] All `await cache.cacheX()` hops replaced with direct in-actor dict access.
- [ ] `ContextManager` reverted from `package` to `internal` (if no other `package` usage exists).
- [ ] Unique test cases ported to actor-level suites; coverage equal or grows.
- [ ] `RuntimeToolPolicyFactory` and its tests preserved unchanged.
- [ ] `make verify` green.
- [ ] CHANGELOG.md updated under `Unreleased`.
- [ ] PKARCH-003 archived ticket annotated with "superseded by PKDEEP-002-impl".
- [ ] No downstream consumer break (public `TimelineManager` surface byte-identical).

### Downstream sync

No public API touched. All affected types are `package`-internal. Zero consumer source references
(confirmed by PKDEEP-002 grep). No downstream grep needed.
