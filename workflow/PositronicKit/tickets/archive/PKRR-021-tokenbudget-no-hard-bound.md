---
Priority: P2
Type: Prompt compression
Depends on: PKRR-001, PKRR-020
Blocks: —
Triage: needs-triage
Status: Done
Confidence: Confirmed
Owner: PKPrompt
Effort: M
Tranche: C (cross-platform generation + public contracts)
Review: PKR-021
Pinned revision: 90646771bd113ae5ffa63816a18153f5fcf9dc9c
Resolution: Implemented 2026-07-28. PositronicKit `d61ae41` (fast-forward to main). Added
verified `TokenBudgetResult` API with hard budget enforcement. Mandatory `.keep` sections
fail typed when impossible. Summarizer errors preserved instead of swallowed. Migrated
`PromptAssembler`. 1518 tests in 224 suites pass on merged main.
---

# PKRR-021 — `TokenBudget` does not enforce its documented hard upper bound and hides summarizer errors

## Summary
`TokenBudget` computes an available hard budget but may return a still-over-budget
reconstruction. `.keep` subtracts tokens even when insufficient; summarizer errors
are swallowed with `try?` and converted to `drop`. The provider may still reject the
prompt after compression, important sections can be dropped without exposing the
actual summarizer failure, and negative budgets have undefined-looking behavior.

## Current problem
- `Sources/PKPrompt/PromptAssembly/Compression/TokenBudget.swift:99-137` — the API
  computes an available hard budget but may return a still-over-budget
  reconstruction.
- `Sources/PKPrompt/PromptAssembly/Compression/TokenBudget.swift:189-230` — `.keep`
  subtracts tokens even when insufficient; summarizer errors are swallowed with
  `try?` and converted to `drop`.

## Impact
The provider may still reject the prompt after compression. Important sections can
be dropped without exposing the actual summarizer failure. Negative budgets have
undefined-looking behavior.

## Recommended change
Return a throwing/result API with `budgetUnsatisfied`, validate ranges, and report
summarizer failures explicitly. Define whether `.keep` means "may exceed budget" or
"mandatory and fail if impossible."

## Acceptance criteria
- [x] Successful budgeting always returns `estimatedTokens <= available`.
- [x] Mandatory-section overflow returns a typed error.
- [x] Compression reports retain root failure identity (summarizer errors not
  swallowed).
- [x] Regression tests reproduce the current over-budget/hidden-error behavior before
  the fix.
- [x] `CHANGELOG.md` updated under Unreleased.

## Verification
`swift test` (PKPrompt); add a budget-enforcement suite. Depends on PKRR-001
(budget separation) and PKRR-020 (no preconditions on recoverable state).
