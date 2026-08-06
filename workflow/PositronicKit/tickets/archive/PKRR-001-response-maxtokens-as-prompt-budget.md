---
Priority: P0
Type: Correctness / prompt budgeting
Depends on: —
Blocks: PKRR-021
Triage: ready-for-agent
Status: Done
Confidence: Confirmed
Owner: Runtime + PKPrompt
Effort: M
Tranche: A (lock terminal/execution invariants)
Review: PKR-001
Pinned revision: 90646771bd113ae5ffa63816a18153f5fcf9dc9c
Resolution: Implemented 2026-07-28. PositronicKit `97b65a8` (merge `8b9d1d1`). Added
`contextWindowTokens` to `ProviderConfiguration` with per-provider defaults (OpenAI/
OpenRouter 128k, Anthropic 200k, Ollama 8k). Added `TokenBudget.init(contextWindow:
outputReserve:)` with typed `TokenBudgetError` validation. `ChatEngine.makeTokenBudget`
derives budget as `contextWindow - (maxOutput ?? 4096) - 512 overhead`. A 512-token output
limit no longer compresses a prompt that fits the context window. 18 new tests. Codable
backward-compatible. 1394 tests in 211 suites pass on merged main.
---

# PKRR-001 — Response `maxTokens` is used as the prompt context-window budget

## Summary
`GenerationParameters.maxTokens` (the response output limit) is fed directly into
`TokenBudget(maxTokens:)` as the whole prompt/context-window budget, so a small
output limit can destructively compress a prompt that fits the model's context
window.

## Current problem
- `Sources/PKShared/SharedTypes/GenerationParameters.swift:15-18` — `maxTokens` is
  documented as the maximum number of **response** tokens.
- `Sources/PositronicKit/Services/Chat/ChatEngine+TurnPreparation.swift:102-106` —
  the same value is converted into `TokenBudget(maxTokens:)` for prompt compression.
- `Sources/PKPrompt/PromptAssembly/Compression/TokenBudget.swift:10-29` —
  `TokenBudget.maxTokens` is documented as the whole prompt/context-window limit.

## Impact
A caller asking for a 512-token answer can cause the entire prompt to be compressed
toward roughly 410 tokens. Context, tools, memories, or instructions may be dropped
even when the provider has a much larger context window. Zero or small output limits
can create a negative prompt budget.

## Recommended change
Separate `maxOutputTokens` from a provider/model `contextWindowTokens` (or an
explicit `PromptBudget`). Derive prompt budget as
`context window − output reserve − provider overhead`. Validate all values before
assembly. Do not infer context capacity from an output limit.

## Acceptance criteria
- [x] Regression test reproduces the current destructive-compression behavior
  (a 512-token output limit compresses a prompt that fits the context window) before
  the fix.
- [x] A 512-token output limit does not reduce a prompt that fits the model context
  window.
- [x] Prompt budgeting rejects non-positive/overflowing capacities with a typed error.
- [x] Provider-specific context windows can be overridden by the host and tested
  independently of output limits.
- [x] `CHANGELOG.md` updated under Unreleased.

## Verification
`swift test` (PKPrompt + PositronicKit targets); add a budget-invariant suite.
Downstream note: this changes a public budgeting contract — audit
`Monad`/`Shuttle`/`Yakamoz` call sites that supply `maxTokens` and follow the
downstream-sync checklist (root `CLAUDE.md`).
