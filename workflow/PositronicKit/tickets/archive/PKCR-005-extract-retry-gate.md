---
Priority: P1
Type: Code duplication
Depends: —
Blocks: —
Triage: ready-for-agent
Status: Done
Confidence: High — verified 2 near-identical copies
Owner: —
Effort: S
Review: Code review 2026-07-29
Pinned revision: a354632
Resolution: Completed 2026-07-29. Added DuplicateContentRetryGate and migrated Anthropic and
Ollama streaming retry paths, preserving empty-tool-call semantics. Full verification passed
with 1610 tests in 238 suites.
---

# PKCR-005 — Extract DuplicateContentRetryGate + markYieldedIfNeeded

## Summary

The Ollama and Anthropic provider clients share near-identical duplicate-content retry gate logic:

1. **`hasYielded` Mutex + retry gate** — `let hasYielded = Mutex(false)` combined with `shouldRetry: { hasYielded.withLock { !$0 } && RetryPolicy.isTransient(error: error) }`.
2. **`markYieldedIfNeeded` method** — checks whether a chunk's delta has non-empty content/reasoning/toolCalls and sets the Mutex to `true`.

## Current problem

- `Sources/PKOllamaProvider/OllamaClient.swift:70,76,153-163` — `hasYielded` Mutex + `markYieldedIfNeeded`.
- `Sources/PKAnthropicProvider/AnthropicClient.swift:98,104,202-210` — `hasYielded` Mutex + `markYieldedIfNeeded`.

Minor behavioral difference: Ollama locks three times (once per field check), Anthropic locks once with a compound `if`.

## Implementation requirements

1. Create a `DuplicateContentRetryGate` type in `PKUtilities` that:
   - Wraps a `Mutex<Bool>`.
   - Exposes `shouldRetry(error: Error) -> Bool` (checks `!hasYielded && RetryPolicy.isTransient(error:)`).
   - Exposes `markYieldedIfNeeded(_ chunk: LLMStreamChunk)` (single `withLock` checking content/reasoning/toolCalls).
2. Replace the `hasYielded` Mutex + `markYieldedIfNeeded` in both Ollama and Anthropic clients with `DuplicateContentRetryGate`.
3. Update `CHANGELOG.md` under `Unreleased`.

## Acceptance criteria

- [ ] `DuplicateContentRetryGate` type added to `PKUtilities`.
- [ ] Ollama and Anthropic clients use the shared type.
- [ ] Single-lock behavior (fixes Ollama's triple-lock inefficiency).
- [ ] `swift build` succeeds.
- [ ] `swift test` passes (1598+ tests).
- [ ] `CHANGELOG.md` updated.
