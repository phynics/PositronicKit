---
Priority: P1
Type: Error contract
Depends: —
Blocks: —
Triage: ready-for-agent
Status: Done
Confidence: Confirmed
Owner: PKShared / PKUtilities
Effort: M
Tranche: C (cross-platform generation + public contracts)
Review: PKR-014
Pinned revision: 90646771bd113ae5ffa63816a18153f5fcf9dc9c
Resolution: Implemented 2026-07-28. PositronicKit `d420581` (fast-forward to main). Added
`CausalError` protocol enabling cross-module causal chain traversal. `ErrorIdentity.extracting`
now recurses through `CausalError` wrappers (`PipelineError`, `LLMStreamError`) to find the
root `PKError` identity. `PipelineError.usesOwnIdentityAsFallback = false` — its stage-failure
code is orchestration context, not the root cause. Provider 429s, blocked tool errors, and
cancellation retain their identity through pipeline wrapping. 23 error-causality tests
(19 unit + 4 integration). 1494 tests in 222 suites pass on merged main.
---

# PKRR-014 — Pipeline wrapping destroys useful underlying error identity for consumers

## Summary
`ErrorIdentity.extracting` only inspects the top-level error and explicitly does not
traverse causes. Stage failures are wrapped in `PipelineError`, and the wrapped
error is delivered to stream consumers. Provider/HTTP/tool/blocked/validation error
identities can collapse to generic pipeline code `4001`, forcing consumers into
substring matching.

## Current problem
- `Sources/PKShared/SharedTypes/ChatEvent.swift:25-73` —
  `ErrorIdentity.extracting` only inspects the top-level error and explicitly does
  not traverse causes.
- `Sources/PKUtilities/Pipeline.swift:145-168` — stage failures are wrapped in
  `PipelineError`.
- `Sources/PositronicKit/Services/Chat/ChatEngine+TurnLoop.swift:158-172` — the
  wrapped error is delivered to stream consumers.

## Impact
Provider, HTTP, tool, blocked, and validation error identities can collapse to
generic pipeline code `4001`. Consumer retry/blocked/auth handling becomes
string-based or impossible.

## Recommended change
Make errors expose a structured causal chain or preserve the root `PKError` identity
alongside stage context. `ChatEvent.ErrorIdentity` should carry both orchestration
location and root cause.

## Acceptance criteria
- [x] A provider 429 retains its provider/http identity through a failed pipeline
  stage.
- [x] Blocked tool errors remain classifiable after wrapping.
- [x] Consumers never need message substring matching for supported errors.
- [x] Regression tests reproduce the current identity collapse before the fix.
- [x] `CHANGELOG.md` updated under Unreleased.

## Verification
`swift test` (PKShared + PKUtilities + PositronicKit); add an error-causality suite.
Coordinate with PKRR-009 (compound pipeline failures) and PKRR-013 (logging error
identity).
