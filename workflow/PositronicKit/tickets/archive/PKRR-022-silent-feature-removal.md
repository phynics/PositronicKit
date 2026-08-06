---
Priority: P2
Type: Graceful degradation
Depends: PKRR-008
Blocks: —
Triage: needs-triage
Status: Done
Confidence: Confirmed
Owner: Runtime
Effort: M
Tranche: D (observability, API hygiene, build confidence)
Review: PKR-022
Pinned revision: 90646771bd113ae5ffa63816a18153f5fcf9dc9c
Resolution: Implemented 2026-07-28. PositronicKit `f52ac9f` (merge `df390bd`). Added
`TurnDegradationPolicy` and `TurnDiagnostic`. Default runtime is `failRequired`; required
context/agent/store/workspace failures abort before generation. Optional failures emit
structured diagnostics in `generationContext` metadata. Origin lookup remains optional and
observable. 1518 tests in 224 suites pass on merged main.
---

# PKRR-022 — Context, agent, origin, and workspace failures silently remove features from a turn

## Summary
Context errors are reduced to empty context; agent/origin lookup errors use `try?`;
workspace resolution/registration failures are silently skipped. The model can
answer without expected memory, identity, origin, or tools while the user sees an
apparently normal response — graceful only in the sense that it continues, not
observable or policy-controlled.

## Current problem
- `Sources/PositronicKit/Services/Chat/ChatEngine+TurnPreparation.swift:54-79` —
  context errors are reduced to empty context; agent/origin lookup errors use
  `try?`.
- `Sources/PositronicKit/Services/Timeline/TimelineManager+Lifecycle.swift:128-163`
  — workspace resolution/registration failures are silently skipped.

## Impact
The model can answer without expected memory, identity, origin, or tools, while the
user sees an apparently normal response. This is graceful only in the sense that it
continues; it is not observable or policy-controlled.

## Recommended change
Add a degradation policy (`failRequired`, `continueWithWarnings`) and emit
structured `TurnDiagnostic` metadata/events. Let providers/extensions declare
required versus optional dependencies.

## Acceptance criteria
- [x] A required agent/workspace/context failure aborts before generation.
- [x] Optional failures are visible to host/UI and logs with stable identity.
- [x] Regression tests reproduce the current silent feature removal before the fix.
- [x] `CHANGELOG.md` updated under Unreleased.

## Verification
`swift test` (PositronicKit); add a degradation-policy suite. Depends on PKRR-008
(typed store errors) for the not-found vs unavailable distinction.
