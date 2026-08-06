---
Priority: P1
Type: Code duplication
Depends: —
Blocks: —
Triage: ready-for-agent
Status: Done
Confidence: High — verified 5 near-identical copies
Owner: —
Effort: M
Review: Code review 2026-07-29
Pinned revision: a354632
Resolution: Completed 2026-07-29. Added the shared LLMClientProtocol sendMessage default and
stream accumulator; retained provider overrides where custom retry/error behavior required it.
PositronicKit build and full verification passed with 1610 tests in 238 suites.
---

# PKCR-003 — Extract shared provider sendMessage default extension + stream accumulation helper

## Summary

Every provider client implements `sendMessage` with the same pattern: create a single user message, call `chatStream`, then loop `for try await` accumulating `fullContent += delta` from `choices.first?.delta.content`. This is duplicated 5 times. The same stream-consumption loop also appears in `LLMServiceProtocol+StructuredOutput.swift` and `PositronicKit+OneShot.swift`.

## Current problem

- `Sources/PKOpenAIProvider/OpenAIClient.swift:140-168` — `sendMessage` implementation.
- `Sources/PKOpenRouterProvider/OpenRouterClient.swift:355-376` — `sendMessage` implementation.
- `Sources/PKAnthropicProvider/AnthropicClient.swift:275-295` — `sendMessage` implementation.
- `Sources/PKOllamaProvider/OllamaClient.swift:295-315` — `sendMessage` implementation.
- `Sources/PKFoundationModelsProvider/FoundationModelsClient.swift:146-163` — `sendMessage` implementation.
- `Sources/PositronicKit/Services/LLM/LLMServiceProtocol+StructuredOutput.swift:23-27` — stream accumulation.
- `Sources/PositronicKit/PositronicKit+OneShot.swift:60-62` — stream accumulation.

## Implementation requirements

1. Add a default `sendMessage` implementation in an `LLMClientProtocol` extension in `PKShared` that:
   - Constructs a single `.user` `LLMMessage`.
   - Calls `chatStream(messages:tools:)`.
   - Accumulates content from the stream.
   - Returns the accumulated string.
2. Add a shared `accumulateStreamContent(_ stream:) async throws -> String` helper (either as a free function or in an extension) for the non-`sendMessage` call sites.
3. Remove the `sendMessage` method body from each provider client that can use the default. Providers that need retry wrapping (OpenAI) may override.
4. Update the `LLMServiceProtocol+StructuredOutput.swift` and `PositronicKit+OneShot.swift` call sites to use the shared helper.
5. Update `CHANGELOG.md` under `Unreleased`.

## Acceptance criteria

- [ ] Default `sendMessage` extension added to `LLMClientProtocol`.
- [ ] At least 3 of 5 provider `sendMessage` overrides removed (those without custom retry).
- [ ] `accumulateStreamContent` helper added and used by structured-output and one-shot paths.
- [ ] `swift build` succeeds.
- [ ] `swift test` passes (1598+ tests).
- [ ] `CHANGELOG.md` updated.
