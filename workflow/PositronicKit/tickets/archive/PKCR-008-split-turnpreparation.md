---
Priority: P2
Type: File splitting / refactoring
Depends: —
Blocks: —
Triage: ready-for-agent
Status: Done
Confidence: High
Owner: —
Effort: M
Review: Code review 2026-07-29
Pinned revision: a354632
Resolution: Completed 2026-07-29. Extracted TurnIdempotencyGate and
ExternalToolOutputSubmissionGate into dedicated files and moved their singleton access to
static shared values without changing behavior. Full verification passed with 1610 tests in
238 suites.
---

# PKCR-008 — Split ChatEngine+TurnPreparation.swift (555 lines)

## Summary

`ChatEngine+TurnPreparation.swift` contains two private gate actors (`TurnIdempotencyGate`, `ExternalToolOutputSubmissionGate`) with file-global singletons, plus a 285-line `prepareSession` method. The gate actors are independent types that should live in their own files.

## Current problem

- `Sources/PositronicKit/Services/Chat/ChatEngine+TurnPreparation.swift:309-335` — `TurnIdempotencyGate` actor + file-global singleton `turnIdempotencyGate`.
- `Sources/PositronicKit/Services/Chat/ChatEngine+TurnPreparation.swift:337-555` — `ExternalToolOutputSubmissionGate` actor + `ReservedToolOutput` struct + file-global singleton.
- `Sources/PositronicKit/Services/Chat/ChatEngine+TurnPreparation.swift:21-306` — `prepareSession` is a 285-line 12-step pipeline.

## Implementation requirements

1. Extract `TurnIdempotencyGate` to its own file `TurnIdempotencyGate.swift` (in `Services/Chat/` or `Services/Chat/Gates/`).
2. Extract `ExternalToolOutputSubmissionGate` + `ReservedToolOutput` to `ExternalToolOutputSubmissionGate.swift`.
3. Keep the file-global singletons as `static let shared` on each actor type (or make them injectable if practical).
4. Optionally: decompose `prepareSession` into sub-methods:
   - Steps 4-6 (history load + augment + validate) → `loadAndValidateHistory(...)`.
   - Steps 8-9 (workspace + agent + origin resolution) → `resolveTurnEntities(...)`.
5. Update `CHANGELOG.md` under `Unreleased`.

## Acceptance criteria

- [ ] `TurnIdempotencyGate.swift` created.
- [ ] `ExternalToolOutputSubmissionGate.swift` created.
- [ ] `ChatEngine+TurnPreparation.swift` reduced to the `prepareSession` method + helpers.
- [ ] File-global singletons moved to `static let shared` on the actor types.
- [ ] `swift build` succeeds.
- [ ] `swift test` passes (1598+ tests).
- [ ] `CHANGELOG.md` updated.
