---
Priority: P1
Type: LLM configuration
Depends: —
Blocks: —
Triage: ready-for-agent
Status: Done
Confidence: Confirmed
Owner: LLM runtime
Effort: S
Tranche: C (cross-platform generation + public contracts)
Review: PKR-018
Pinned revision: 90646771bd113ae5ffa63816a18153f5fcf9dc9c
Resolution: Implemented 2026-07-28. PositronicKit `a03d540` (fast-forward to main). Added
`isReady` property requiring valid configuration AND a resolved primary client. `isConfigured`
retains configuration-only semantics (backward-compatible). Health details now distinguish
invalid config vs missing client factory vs ready. Added `LLMServiceError.clientNotResolved`
(error code 1008). 6 regression tests. 1500 tests in 222 suites pass on merged main.
---

# PKRR-018 — `LLMService` can report configured while it has no client capable of sending

## Summary
Direct configuration sets `isConfigured = configuration.isValid`, while a missing
factory yields `nil` clients. Streaming then returns `.notConfigured` when no client
exists. Preflight health/configuration checks pass and the actual request fails
later; the state name conflates valid settings with operational readiness.

## Current problem
- `Sources/PositronicKit/Services/LLM/LLMService.swift:118-143` — direct
  configuration sets `isConfigured = configuration.isValid`, while a missing factory
  yields `nil` clients.
- `Sources/PositronicKit/Services/LLM/LLMService+Stream.swift:73-88` — streaming
  then returns `.notConfigured` when no client exists.

## Impact
Preflight health/configuration checks pass and the actual request fails later. The
state name conflates valid settings with operational readiness.

## Recommended change
Split `configurationIsValid` from `isReady`, or define `isConfigured` as valid
configuration plus a resolved primary client. Fail initialization or return a typed
readiness diagnostic when a valid config has no factory/client.

## Acceptance criteria
- [x] `isConfigured == true` guarantees a primary send can start.
- [x] Health details explain invalid settings versus missing client factory.
- [x] Regression test reproduces the current configured-but-no-client state before
  the fix.
- [x] `CHANGELOG.md` updated under Unreleased.

## Verification
`swift test` (PositronicKit LLM targets). Public API change — audit
`Monad`/`Shuttle`/`Yakamoz` health/config surfaces and follow the downstream-sync
checklist.
