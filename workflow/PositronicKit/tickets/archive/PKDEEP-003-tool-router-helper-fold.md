# PKDEEP-003 — Fold ToolRouter shallow helpers back into the router

**Priority:** P3
**Type:** Research / architecture-review follow-up (deepening candidate)
**Depends on:** none
**Blocks:** PKDEEP-007 (folded cleanup of `WorkspaceResolutionProvider` hypothetical seam lands with this)
**Triage:** ready-for-agent
**Status:** Done (research) — promoted to PKDEEP-003-impl

### Summary

`ToolRouter.handlePendingToolCalls` always calls four sibling files in the same fixed
sequence: `ToolRoutingDecision` → `ToolTurnProjector.projectAttempt` →
`ToolExecutor.execute` → `ToolTurnProjector.projectOutcome`/`projectError`. Following one
tool call crosses four files. `ToolExecutor` is the shallowest: tool-manager lookup, a
`requiresPermission` gate, then `ToolTimeoutEnforcer.execute`. Each helper has **no second
caller anywhere** outside `ToolRouter`. `ToolTimeoutEnforcer` is the genuinely deep piece
(a `withTaskCancellationHandler` + `withCheckedThrowingContinuation` race against a sleep,
with a `TimeoutRaceResolver` actor ensuring only one race winner resumes); it earns its
keep as a separate module. The candidate is to fold `ToolExecutor`, `ToolTurnProjector`,
and `ToolRoutingDecision` back into `ToolRouter`, keep `ToolTimeoutEnforcer` standalone,
and honestly label or retire the `WorkspaceResolutionProvider` protocol (sole production
adapter: `TimelineManager`).

**Conflict note with PKARCH-002 (closed, commit `01e871a`):** PKARCH-002 *introduced* this
exact four-file split on 2026-07-07 ("split `ToolRouter` into four package-internal
modules: `ToolTimeoutEnforcer`, `ToolExecutor`, `ToolRoutingDecision`, `ToolTurnProjector`
… 18 new isolation tests"). Same-day closure; the friction is real but the prior decision
must be explicitly re-litigated.

### Current problem (with file:line references)

- `Sources/PositronicKit/Services/Tools/ToolRouter.swift` (~213 lines after the PKARCH-002
  split) — orchestrator that always calls the four siblings in one fixed order.
- `Sources/PositronicKit/Services/Tools/ToolExecutor.swift` (~101 lines) — tool-manager
  lookup + `requiresPermission` gate + delegate to `ToolTimeoutEnforcer`. Shallow.
- `Sources/PositronicKit/Services/Tools/ToolTurnProjector.swift` (~80 lines) — projects
  `.attempting`, `.outcome`, `.error` events onto the message store. One caller
  (`ToolRouter`).
- `Sources/PositronicKit/Services/Tools/ToolRoutingDecision.swift` (~130 lines) — static
  `resolveToolReference` + the `WorkspaceResolutionProvider` protocol (sole production
  adapter: `TimelineManager`).
- `Sources/PositronicKit/Services/Tools/ToolTimeoutEnforcer.swift` (~101 lines) — the one
  deep piece; survives.

**Deletion test result (mixed):**
- Delete `ToolExecutor` → ~30 lines reappear in `ToolRouter`. Pass-through.
- Delete `ToolTurnProjector` → ~80 lines reappear inline. Pass-through.
- Delete `ToolRoutingDecision` → ~30 lines reappear as static helpers. Pass-through.
- Delete `ToolTimeoutEnforcer` → ~60 lines of fiddly continuation-race code reappear.
  **Keep.**

### Research scope

1. **Re-litigate PKARCH-002 explicitly.** Re-read the archived PKARCH-002 ticket;
   summarize its stated rationale ("isolation tests", "router reduced 420 → 213 lines").
   Decide whether the 18 isolation tests added by PKARCH-002 actually test deep
   behaviour (race correctness in `ToolTimeoutEnforcer`, permission-gate edge cases) or
   just router-helper wiring. Only the deep ones earn their own file.
2. **Audit `WorkspaceResolutionProvider`.** Grep the workspace for conformers. Expected:
   `TimelineManager` + a test fake. Confirm one adapter (hypothetical seam) — or surface
   a real second adapter, in which case the seam stays. If one-adapter, decide between
   (a) collapse: `ToolRoutingDecision.resolveWorkspace` receives a `TimelineManager`
   directly (package-internal friend), drop the protocol; (b) widen: a real second
   adapter is plausible (e.g. when Shuttle runs tools per-shard without a full
   `TimelineManager`), keep the protocol but document the planned adapter.
3. **Audit `ToolTurnProjector` locality claim.** The projection correctness vis-à-vis
   the message store is the real bug surface (matcher results, error remediation
   formatting). If folded into `ToolRouter`, is the projection logic still testable
   through `ToolRouter.handlePendingToolCalls`? If yes, fold; if the projection's
   correctness tests need a narrower surface, keep `ToolTurnProjector` but drop its
   protocol-ish indirection.
4. **Audit `ToolExecutor`.** Specifically whether the `requiresPermission` gate is
   independently testable (likely yes in PKARCH-002's isolation tests) and whether that
   independent testability carries value vs testing through `ToolRouter` with a fake
   tool manager. Decide fold vs keep.
5. **Downstream impact.** Grep Monad, Shuttle, Yakamoz for `ToolExecutor`,
   `ToolTurnProjector`, `ToolRoutingDecision`, `WorkspaceResolutionProvider`. Expected:
   zero (all `package`-internal). Confirm.
6. **Test churn estimate.** The 18 isolation tests added by PKARCH-002 partially target
   the helpers slated for folding. Estimate which tests are deleted (wiring tests) and
   which are recast as `ToolRouter` tests. Confirm coverage delta is non-negative.

### Acceptance criteria

- [x] PKARCH-002 rationale summarized; explicit re-open decision recorded.
- [x] `WorkspaceResolutionProvider` adapter audit recorded; one-adapter confirmed or
      second-adapter surfaced.
- [x] Per-helper fold decision: `ToolExecutor`, `ToolTurnProjector`, `ToolRoutingDecision`
      — fold or keep, each with rationale.
- [x] `ToolTimeoutEnforcer` confirmed deep; stays standalone.
- [x] Test churn + coverage delta stated.
- [x] Downstream grep clean (or named external callers identified).
- [x] Final finding: **promote** (`PKDEEP-003-impl`; if it reverts PKARCH-002 partially,
      the impl ticket supersedes PKARCH-002 in its resolution note and adds an ADR if
      the reversal is structural) **or reject** (ADR if the reason is load-bearing).
- [x] If implemented, PKARCH-002's archived ticket is annotated with a "partially
      superseded by PKDEEP-003-impl on <date>" line specifying which helpers re-folded.

### Research findings (2026-07-08)

#### 1. PKARCH-002 re-litigation

**PKARCH-002 rationale** (2026-07-07, commit `01e871a`): `ToolRouter.swift` was 420 lines
with 6 responsibilities (tool-call normalization, workspace resolution, local-vs-external
routing, local execution, wall-clock timeout enforcement, event projection). The split
extracted 4 modules and added 18 isolation tests. Router reduced 420 → 213 lines.

**Re-open decision: YES, partially.** Of the 4 extracted modules:
- `ToolTimeoutEnforcer` (101 lines, 9 isolation tests) — genuinely deep. The
  `withTaskCancellationHandler` + `withCheckedThrowingContinuation` race with
  `TimeoutRaceResolver` actor is real concurrency machinery. Its 9 isolation tests test
  deep behavior (fake clock, uncooperative blocking tool, cancellation semantics). **Stays.**
- `ToolExecutor` (102 lines) — shallow. Tool-manager lookup (3-line closure) +
  `requiresPermission` gate + delegate to `ToolTimeoutEnforcer`. **Fold.**
- `ToolTurnProjector` (80 lines) — side-effectful mapping (event emission + message store
  persistence + error remediation formatting). Called in exactly 3 places within
  `handlePendingToolCalls`. **Fold.**
- `ToolRoutingDecision` (130 lines) — static helpers (`resolveToolReference`,
  `outcomeForWorkspace`, `resolveWorkspace`) + the `WorkspaceResolutionProvider` protocol.
  **Fold** (including protocol retirement).

The 18 isolation tests break down:
- 9 `ToolTimeoutEnforcerTests` — deep, preserved.
- 9 `ToolRoutingDecisionWorkspaceResolutionTests` — test routing policy with a
  `FakeProvider`. High churn but behaviors are partly covered by the 14 `ToolRouterTests`
  integration tests.
- 3 `ToolTurnProjectorTests` — test projection in isolation. Medium churn.
- 2 `ToolRoutingDecisionTests` (in `ToolRouterTests.swift`) — redundant duplicates.

#### 2. WorkspaceResolutionProvider adapter audit

**One production adapter confirmed** (`TimelineManager`) + one test fake (`FakeProvider`
in `ToolRoutingDecisionWorkspaceResolutionTests`). The protocol's sole purpose is to make
`resolveWorkspace` testable without a `TimelineManager`. The `ToolRouter.execute` call site
(`ToolRouter.swift:248`) passes `timelineManager` directly as the `provider`.

The protocol's 5 methods are all forwarding wrappers:
- `workspaces(for:)` → `getWorkspaces(for:)`
- `timelineIsPrivate(id:)` → `getTimeline(id:)?.isPrivate`
- `toolManager(for:)` → `getToolManager(for:)`
- `findWorkspaceForTool(_:in:)` — already on `TimelineManager`
- `getWorkspace(_:)` — already on `TimelineManager`

**Decision: retire the protocol.** `ToolRouter` already holds a `timelineManager`
reference. The protocol adds 5 forwarding methods and a test fake for no real benefit — the
14 `ToolRouterTests` integration tests already exercise workspace resolution through
`ToolRouter.execute` with a real `TimelineManager` (via `TestRuntime`). The 9 isolation
tests' edge cases (malformed UUID, unattached UUID, workspace lookup order) can be recast
as `ToolRouter`-level tests.

#### 3. Per-helper fold decisions

| Helper | Lines | Decision | Rationale |
|--------|-------|----------|-----------|
| `ToolTimeoutEnforcer` | 101 | **Keep** | Deep continuation-race machinery; 9 genuine isolation tests |
| `ToolExecutor` | 102 | **Fold** | Shallow: tool-manager lookup (3-line closure) + permission gate + delegate to enforcer |
| `ToolTurnProjector` | 80 | **Fold** | Side-effectful mapping called in 3 places in one method; testable through `handlePendingToolCalls` |
| `ToolRoutingDecision` | 130 | **Fold** | Static pure-function helpers + hypothetical-seam protocol; all fields available on `ToolRouter` |

#### 4. Downstream grep: CLEAN

Zero direct code usages of any of the 5 symbols (`ToolExecutor`, `ToolTurnProjector`,
`ToolRoutingDecision`, `WorkspaceResolutionProvider`, `ToolTimeoutEnforcer`) in compiled
code across Monad, Shuttle, or Yakamoz. The only non-zero hits are:
- 4 Monad false-positives (`ClientToolExecutor`, `ToolExecutorError` — substring matches
  on different types)
- 3 Yakamoz doc/test comments mentioning `ToolTurnProjector` by name (would become stale
  references but won't break compilation)

#### 5. Test churn + coverage delta

39 tool-routing-relevant test cases across 4 files:

| File / Suite | Tests | Churn | Plan |
|---|---|---|---|
| `ToolTimeoutEnforcerTests` | 9 | None | Stays standalone |
| `ToolRouterTests.ToolRouterTests` | 14 | Low | Already integration-tests through `ToolRouter`; unchanged |
| `ToolRouterConcurrencyTests` | 2 | Low | Already tests through `ToolRouter` |
| `ToolRoutingDecisionWorkspaceResolutionTests` | 9 | High | Recast as `ToolRouter`-level tests (or delete if covered by integration tests) |
| `ToolRouterTests.ToolTurnProjectorTests` | 3 | Medium | Recast as `handlePendingToolCalls` assertions |
| `ToolRouterTests.ToolRoutingDecisionTests` | 2 | Medium | Delete (redundant duplicates) |

**Coverage delta: non-negative.** The 14 integration tests + 2 concurrency tests already
exercise the approval gate, workspace resolution, deferral, dynamic tools, `workspaceID`
validation, and timeout projection through `ToolRouter`. The 9 `ToolTimeoutEnforcer`
isolation tests are preserved. The at-risk coverage is the narrow edge cases (malformed UUID
fallback, unattached UUID fail-closed, workspace lookup order, error remediation surfacing)
— these should be recast as `ToolRouter`-level tests, not deleted, before removing the
helper files.

#### 6. Final finding: PROMOTE to PKDEEP-003-impl

- Fold `ToolExecutor`, `ToolTurnProjector`, `ToolRoutingDecision` back into `ToolRouter`
- Retire `WorkspaceResolutionProvider` protocol
- Keep `ToolTimeoutEnforcer` standalone
- Recast ~12 isolation tests as `ToolRouter`-level tests; delete 2 redundant duplicates
- PKARCH-002 partially superseded (3 of 4 helpers re-folded; `ToolTimeoutEnforcer` stays)
- PKDEEP-007's `WorkspaceResolutionProvider` audit item is resolved by this ticket

### Downstream sync

Research only; no implementation. Any impl is package-internal by default. If
`WorkspaceResolutionProvider` is retired and Shuttle or Yakamoz conforms to it (unlikely —
expected zero), coordinate a consumer release.