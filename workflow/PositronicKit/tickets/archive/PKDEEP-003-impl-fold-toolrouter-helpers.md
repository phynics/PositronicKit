# PKDEEP-003-impl — Fold ToolRouter shallow helpers back into the router

**Priority:** P3
**Type:** Implementation (deepening)
**Depends on:** PKDEEP-003 (research, done)
**Blocks:** PKDEEP-007 (resolves the `WorkspaceResolutionProvider` hypothetical seam audit item)
**Triage:** ready-for-agent
**Status:** Done (2026-07-08, commit `cb85a09`)

### Summary

Fold `ToolExecutor` (102 lines), `ToolTurnProjector` (80 lines), and `ToolRoutingDecision`
(130 lines) back into `ToolRouter` as private methods. Retire the `WorkspaceResolutionProvider`
protocol (hypothetical seam — one production adapter). Keep `ToolTimeoutEnforcer` (101 lines)
standalone. Partially supersedes PKARCH-002 (3 of 4 helpers re-folded; `ToolTimeoutEnforcer`
stays).

### Context

PKARCH-002 (2026-07-07, commit `01e871a`) split `ToolRouter` into 4 modules. PKDEEP-003
research confirmed 3 of 4 are shallow pass-throughs with no second caller outside
`ToolRouter`. The 4th (`ToolTimeoutEnforcer`) is genuinely deep (continuation-race
machinery, 9 isolation tests). The `WorkspaceResolutionProvider` protocol has one production
adapter (`TimelineManager`) and one test fake — its 5 methods are all forwarding wrappers.

### Implementation requirements

1. **Fold `ToolExecutor` into `ToolRouter`**: Move the `execute(tool:arguments:lookup:dynamicTools:)`
   method body into a `private func executeLocally(...)` on `ToolRouter`. The `ToolExecutor`
   struct, its `init`, its `approvalGate`/`timeout`/`sleep`/`logger` fields, and its doc
   comments are deleted. `ToolRouter` already holds `approvalGate`, `toolExecutionTimeout`,
   and `logger`. The `sleep` closure should be injected via `ToolRouter.init` (default:
   `ToolTimeoutEnforcer.defaultSleep`) so the fake-clock tests still work.

2. **Fold `ToolTurnProjector` into `ToolRouter`**: Move `projectAttempt`, `projectOutcome`,
   and `projectError` as private methods on `ToolRouter`. They already use `ToolRouter`'s
   `logger`, `messageStore`, and `continuation`. Delete the `ToolTurnProjector` enum and
   its file.

3. **Fold `ToolRoutingDecision` into `ToolRouter`**: Move `resolveToolReference`,
   `outcomeForWorkspace`, and `resolveWorkspace` as private methods on `ToolRouter`.
   `resolveWorkspace` calls `timelineManager` directly instead of through the
   `WorkspaceResolutionProvider` protocol. Delete the `ToolRoutingDecision` enum, the
   `WorkspaceResolutionProvider` protocol, the `TimelineManager` conformance extension,
   and the `WorkspaceExecutionDisposition` enum (inline as a private enum on `ToolRouter`
   or just use a bool/switch).

4. **Delete files**: `ToolExecutor.swift`, `ToolTurnProjector.swift`, `ToolRoutingDecision.swift`.
   Keep `ToolTimeoutEnforcer.swift`.

5. **Inject `sleep` closure**: Add a `sleep` parameter to `ToolRouter.init` (default:
   `ToolTimeoutEnforcer.defaultSleep`) so the fake-clock timeout tests still work through
   `ToolRouter`. Store it as a private field. The `executeLocally` method passes it to
   `ToolTimeoutEnforcer.execute`.

6. **Update `ToolRouter.handlePendingToolCalls`**: Replace `ToolRoutingDecision.resolveToolReference`
   with a private method call. Replace `ToolTurnProjector.projectAttempt/projectOutcome/projectError`
   with private method calls. Replace `executor.execute(...)` with `executeLocally(...)`.

7. **Update `ToolRouter.execute`**: Replace `ToolRoutingDecision.resolveWorkspace` and
   `ToolRoutingDecision.outcomeForWorkspace` with private method calls. Replace
   `executor.execute(...)` with `executeLocally(...)`.

8. **Recast tests**:
   - `ToolRoutingDecisionWorkspaceResolutionTests.swift` (9 tests) — recast as
     `ToolRouter`-level tests using `TestRuntime`'s `TimelineManager`, or delete if the
     behavior is already covered by the 14 `ToolRouterTests` integration tests. Pay
     attention to the edge cases: malformed UUID fallback, unattached UUID fail-closed,
     workspace lookup order (primary then attached). These must remain covered.
   - `ToolRouterTests.ToolTurnProjectorTests` (3 tests) — recast as
     `handlePendingToolCalls` assertions (assert on the resulting messages and events).
   - `ToolRouterTests.ToolRoutingDecisionTests` (2 tests) — delete (redundant duplicates).
   - `ToolTimeoutEnforcerTests.swift` (9 tests) — unchanged.
   - `ToolRouterTests.ToolRouterTests` (14 tests) — likely unchanged (already integration
     tests through `ToolRouter`).
   - `ToolRouterConcurrencyTests.swift` (2 tests) — unchanged.

### Acceptance criteria

- [ ] `ToolExecutor.swift`, `ToolTurnProjector.swift`, `ToolRoutingDecision.swift` deleted
- [ ] `ToolTimeoutEnforcer.swift` unchanged
- [ ] `WorkspaceResolutionProvider` protocol retired
- [ ] `ToolRouter` holds the folded logic as private methods
- [ ] `sleep` closure injectable via `ToolRouter.init` for fake-clock tests
- [ ] No public API change (`ToolRouter` public `init` and methods unchanged or
      backwards-compatible — the `sleep` parameter has a default)
- [ ] Test coverage non-negative (edge cases preserved)
- [ ] `make verify` green

### Downstream sync

All affected symbols are `package`-internal. Zero downstream references confirmed by grep.
No consumer coordination needed.

### Verification

```bash
cd PositronicKit
make verify
```

### Cross-links

- Research: [PKDEEP-003](../PKDEEP-003-tool-router-helper-fold.md)
- Partially supersedes: [PKARCH-002](../archive/PKARCH-002-split-toolrouter-into-execution-seams.md)
  (3 of 4 helpers re-folded; `ToolTimeoutEnforcer` stays)
- Resolves: PKDEEP-007's `WorkspaceResolutionProvider` audit item
