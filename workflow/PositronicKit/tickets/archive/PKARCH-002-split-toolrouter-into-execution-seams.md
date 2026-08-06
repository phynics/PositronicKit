# PKARCH-002: Split ToolRouter into execution seams

**Priority:** P2
**Type:** Internal refactor (public `ToolRouter.processToolCalls(...)` interface remains stable; new internal seams are package-private)
**Depends on:** PKARCH-003 (TimelineManager lifecycle extraction; `ToolResolver` depends on a stable workspace attachment seam)
**Blocks:** None
**Triage:** done
**Status:** Done (2026-07-07, commit `01e871a`) — extracted `ToolTimeoutEnforcer` (wall-clock race + injected
`sleep` closure for fake-clock testing), `ToolExecutor` (approval-gate + tool-manager lookup +
dynamic-tool priority merge + dispatch), `ToolRoutingDecision.resolveWorkspace` (explicit
`workspaceID` validation + provider-backed lookup behind a new `package WorkspaceResolutionProvider`
protocol that `TimelineManager` conforms to), and extended `ToolTurnProjector` to own the
`.attempting` tool-progress event. `ToolRouter.swift` reduced from 420 to 213 lines and is now a
thin coordinator delegating to the four modules. `TimeoutRaceResolver` actor and
`executeWithTimeout`/`timeoutDescription` helpers moved out of `ToolRouter.swift`. 18 new
isolation tests (`ToolTimeoutEnforcerTests` incl. fake-clock + uncooperative blocking tool,
`ToolRoutingDecisionWorkspaceResolutionTests` covering workspace/explicit-workspaceID/malformed-id/no-workspace
paths); existing `ToolRouterTests`/`ToolRouterConcurrencyTests`/`ChatEngine*Tests` still green.
`swift test` 851 tests / 154 suites; `make verify` and `make verify-products` green. No
downstream references to the new package-internal symbols.

**Partially superseded by PKDEEP-003-impl on 2026-07-08:** `ToolExecutor`, `ToolTurnProjector`,
and `ToolRoutingDecision` are folded back into `ToolRouter` as private methods.
`WorkspaceResolutionProvider` protocol retired (one production adapter — hypothetical seam).
`ToolTimeoutEnforcer` stays standalone (genuinely deep continuation-race machinery).

### Summary

`ToolRouter` is currently a public actor that owns six responsibilities: tool-call normalization, workspace resolution, local vs. external routing, local execution, wall-clock timeout enforcement, and tool progress/completion event projection. This ticket splits those concerns into narrow modules behind a thin `ToolRouter` coordinator.

### Current Problem

- `ToolRouter.swift` is 420 lines and explicitly documents its own scope creep in its header comment.
- The only public seam is `execute(...)` / `processToolCalls(...)`, so testing timeout behavior requires bringing up a `TimelineManager` and message store.
- The deletion test fails: deleting `ToolRouter` would scatter normalization, routing, timeout, and event projection across the chat loop.

### Implementation Requirements

1. Extract focused internal modules:
   - `ToolResolver` — owns `resolveWorkspace`, explicit `workspaceID` argument handling, and dynamic-tool lookup from `availableTools`.
   - `ToolExecutor` — owns the approval-gate check, tool-manager lookup, and dispatch to the concrete tool.
   - `ToolTimeoutEnforcer` — owns the wall-clock timeout race (`executeWithTimeout`), reusable as a generic timeout wrapper.
   - `ToolEventProjector` — owns `ToolTurnProjector` and the projection of progress, completion, and error events back into the chat stream, plus result persistence.
2. `ToolRouter` keeps the public `processToolCalls(...)` and `execute(...)` signatures but delegates to the new modules.
3. Preserve the current behavior: malformed-argument handling, permission-gate denial, private-timeline external-tool restrictions, dynamic-tool priority, and timeout race semantics.

### Acceptance Criteria

- [ ] `ToolRouter.swift` is reduced to a thin coordinator; the four extracted modules live in their own files.
- [ ] `ToolTimeoutEnforcer` can be tested with a fake tool and a fake clock, without a `TimelineManager`.
- [ ] `ToolResolver` tests cover workspace lookup, explicit workspaceID argument validation, and dynamic-tool fallback.
- [ ] `ToolEventProjector` tests cover progress/completion/error event projection and result persistence.
- [ ] Existing `ToolRouter` tests still pass; no behavioral regression.
- [ ] `make verify` green.
