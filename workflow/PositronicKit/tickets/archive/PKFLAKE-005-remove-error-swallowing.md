# PKFLAKE-005 — Remove `try?` error swallowing on hydration and agent message persistence

**Priority:** P2
**Type:** Bug (silent failure)
**Depends on:** —
**Blocks:** —
**Triage:** ready-for-agent
**Status:** Done (2026-07-09, commit `d406242`) — `AgentInstanceManager.attach`/`detach`'s audit-
log saves and `deleteInstance`'s private-timeline delete now log at `.warning`/`.error` with
`ErrorKit.userFriendlyMessage(for:)` and the relevant identifiers instead of swallowing via bare
`try?`, then continue (the underlying operation had already succeeded — an audit-log/cleanup
failure shouldn't fail it). For `PositronicKit.resolveContextManager`'s hydration call: an
initial implementation propagated the error (`throws`), but this broke 15 tests that construct
a fresh, never-persisted timeline and rely on `hydrateTimeline` failing with
`TimelineError.timelineNotFound` as the *expected* first-message flow, not a fault — the same
error shape a transient store failure would produce. Corrected to log-and-continue (`.error`
level, timeline ID + friendly message, documented in a doc comment) rather than propagate,
matching the ticket's explicit "or, if intentionally best-effort, log" alternative. Added
`FailingMessageStore`/`FailingTimelinePersistence` mocks (`Tests/PKTestSupport/FailingStores.swift`)
and tests covering attach/detach/delete survival plus hydration-failure log-and-continue.
`swift test`: 900 tests / 157 suites green (pre-merge); the other 3 orchestration-layer `try?`
sites the ticket asked to sweep (`TimelineManager+Attachments.swift`, `TimelineManager+Lifecycle.swift`,
tool-lookup sites) were reviewed and intentionally left — each is an optional-binding read where
a missing value is legitimate control flow, not a swallowed fault.

### Summary

Two production paths discard errors with `try?`, producing nondeterministic downstream
behavior that is impossible to attribute:

- `Sources/PositronicKit/PositronicKit.swift:329` — `try? await timelineManager.hydrateTimeline(...)`:
  a transient persistence error yields a silently partially-hydrated timeline (missing
  messages/tools/context).
- `Sources/PositronicKit/Services/Agents/AgentInstanceManager.swift:173, 204` —
  `try? await messageStore.saveMessage(...)`: agent lifecycle audit records are dropped
  without trace on persistence failure.

### Implementation Requirements

1. Hydration: either propagate the error to the caller (preferred — callers should know
   the timeline is unusable) or, if intentionally best-effort, log at `.error` with
   `ErrorKit.userFriendlyMessage(for:)` and the timeline ID, and document why the turn
   may proceed unhydrated.
2. Agent message saves: log failures at `.warning`/`.error` with agent instance ID; decide
   per call site whether to propagate. Do not leave bare `try?`.
3. Sweep `Sources/` for other `try?` on persistence/hydration calls in the orchestration
   layer and treat them the same way (list them in the resolution note).
4. Add tests using a failing mock store asserting the new behavior (error thrown or
   logged-not-swallowed).

### Acceptance Criteria

- [ ] No bare `try?` remains on the three cited call sites.
- [ ] Tests cover failing-store behavior for hydration and agent message saves.
- [ ] `make verify` green.
