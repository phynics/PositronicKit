# PKCOV-001 — Direct unit tests for `WorkspaceManager`

**Priority:** P1
**Type:** Test coverage
**Depends on:** —
**Blocks:** —
**Triage:** ready-for-agent
**Status:** Done — created `WorkspaceManagerTests.swift` with 11 behavioral tests covering cache lifecycle, unknown IDs, error propagation, health-check aggregation/eviction, and concurrent interleaving. Merged `7edbe2e`; `make verify` green (896 tests / 156 suites).

### Summary

`Sources/PositronicKit/Services/Workspace/WorkspaceManager.swift` (public API:
`activeWorkspaceCount`, `getWorkspace(id:)`, `closeWorkspace(id:)`, `healthCheckAll()`)
has **zero dedicated tests** — only incidental coverage via `AgentWorkspaceServiceTests`
and ChatEngine integration. Workspace lifecycle is a critical release interface.

### Implementation Requirements

Create `Tests/PositronicKitTests/Services/Workspace/WorkspaceManagerTests.swift`
(Swift Testing, `PKTestSupport` mocks) covering at minimum:

1. Cache lifecycle: open → get returns same instance; close evicts; count tracks.
2. `getWorkspace` for unknown ID (nil/throw contract pinned).
3. `healthCheckAll` aggregation, including a workspace whose health check throws/fails,
   and any eviction-on-unhealthy behavior (pin whatever the current contract is).
4. Concurrent open/close/get interleaving (actor-safety smoke: e.g. `taskGroup` of mixed
   operations asserting invariants, no crashes, consistent count).

### Acceptance Criteria

- [ ] ≥10 behavioral tests, all against the public API.
- [ ] Health-check failure path covered.
- [ ] `make verify` green.
