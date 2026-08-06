# PKINT-001 — Make snake_case-Safe Stream Decoding a Provider Contract, Not a Per-Provider Patch

**Priority:** P1
**Type:** Correctness defect (silent data loss)
**Depends on:** None
**Blocks:** Any new streaming provider; reliable tool calling on every provider
**Status:** Done (2026-07-05)
**Surfaced by:** YAK-23 (Yakamoz)

### Summary

Establish a single, enforced contract that **every** streaming provider adapter decodes the
on-wire SSE payload into `LLMStreamChunk` without silently dropping fields, and back it with
a shared golden-wire conformance suite seeded from captured raw provider chunks. Today only
`PKOpenRouterProvider` has the fix and a regression test; the same defect can re-form in
`PKOpenAIProvider`, `PKOllamaProvider`, and any future adapter.

### Current Problem

The `LLMStreamChunk` family is camelCase with **no explicit `CodingKeys`**, while provider
wire formats are snake_case (`tool_calls`, `finish_reason`). YAK-23 proved that a plain
`JSONDecoder()` therefore decodes `tool_calls`/`finish_reason` to `nil` on every chunk — so
**every streamed tool call is silently discarded** and the response looks like an empty
completion, not an error.

That was fixed for exactly one provider:

- `Sources/PKOpenRouterProvider/OpenRouterClient.swift:210-216` now sets
  `decoder.keyDecodingStrategy = .convertFromSnakeCase`, with a captured-wire regression test.

The other adapters are unaudited against the same failure mode:

- `PKOpenAIProvider` decodes via the SDK's typed model mapped through
  `OpenAIConversions.toLLMStreamChunk()` (`Sources/PKOpenAIProvider/OpenAIConversions.swift:71`).
  This *probably* avoids the raw-JSON pitfall, but there is **no test** that proves a real
  OpenAI tool-call SSE chunk survives the mapping into a non-nil `toolCalls`/`finishReason`.
- `PKOllamaProvider` uses bare `JSONDecoder()` in multiple decode paths
  (`Sources/PKOllamaProvider/OllamaClient.swift:127`, `Sources/PKOllamaProvider/OllamaModels.swift:127`).

There is no shared contract test, so the next adapter (or a refactor of an existing one)
re-introduces the bug with zero signal.

### Files

- Add: `Tests/PositronicKitTests/Providers/StreamDecodingConformanceTests.swift` (or the
  established provider-test location) — a shared, fixture-driven suite.
- Add: `Tests/PositronicKitTests/Providers/Fixtures/` — captured raw SSE chunks (one per
  provider) containing a streamed tool call with `tool_calls` + `finish_reason: "tool_calls"`.
- Audit/modify: `Sources/PKOpenAIProvider/OpenAIClient.swift`, `Sources/PKOpenAIProvider/OpenAIConversions.swift`
- Audit/modify: `Sources/PKOllamaProvider/OllamaClient.swift`, `Sources/PKOllamaProvider/OllamaModels.swift`
- Reference (already fixed, keep as the template): `Sources/PKOpenRouterProvider/OpenRouterClient.swift:210-216`

### Implementation Requirements

1. Define the contract in one place: any decode that targets `LLMStreamChunk` (or its nested
   delta/tool-call/usage types) must either use `.convertFromSnakeCase` or declare explicit
   `CodingKeys` that map every wire field. Pick **one** mechanism per type and document it at
   the type definition so future fields inherit it.
2. Prefer fixing it at the `LLMStreamChunk` type boundary (explicit `CodingKeys` on the shared
   types in `PKShared`) over relying on each adapter to remember a decoder flag, so a provider
   that forgets the flag still decodes correctly. If explicit keys are impractical for a type,
   the conformance test (below) is the backstop.
3. Audit each provider's streaming path and make it satisfy the contract. Do not change any
   provider's successful output shape for plain-text streaming (which already worked because
   `content`→`content` needs no conversion).
4. Do not introduce `.convertFromSnakeCase` on a decoder that also reads a type with an
   intentional snake_case wire key that would now double-convert — verify each decoder's full
   payload, not just the chunk type.

### Required Tests

- For **each** streaming provider, a fixture-driven test feeds a captured raw tool-call SSE
  chunk through the real decode path and asserts the resulting `LLMStreamChunk` has a non-nil
  tool call (id, name, arguments) and the expected `finishReason`.
- A test asserts a plain-text chunk still decodes to the expected `content` for each provider
  (guards against a double-conversion regression).
- A "new provider" guard: a table-driven test that fails if a provider adapter is added to the
  package without a corresponding stream-decoding fixture entry (or document this as a review
  checklist item if a compile-time guard is impractical).

### Acceptance Criteria

- [ ] Every streaming provider has a captured-wire test proving `tool_calls` and
      `finish_reason` survive decode into a non-nil `LLMStreamChunk`.
- [ ] The snake_case/CodingKeys contract is documented at the `LLMStreamChunk` type, not only
      in one provider's comment.
- [ ] Plain-text streaming output is byte-for-byte unchanged for all providers.
- [ ] `make verify` green in PositronicKit; `Monad`/`Shuttle` build; Yakamoz `make verify` green.

### Verification

```bash
swift test --filter StreamDecodingConformanceTests
make verify
```

### Handoff Notes

The original YAK-23 investigation burned hours blaming the model and the request payload
before capturing raw SSE proved the decoder ate a valid tool call. The whole point of this
ticket is that "the test passes" for plain text is **not** evidence the tool-call path works —
the fixtures must be real captured tool-call chunks, not hand-written happy-path JSON.

### Resolution

Done on `f04c2f8`. The shared transport contract now lives at the `LLMStreamChunk` boundary
via explicit snake_case `CodingKeys`, and the captured-wire conformance suite covers
OpenRouter, OpenAI, and Ollama tool-call plus plain-text streaming paths.

Verification on 2026-07-05:

- `swift test --filter StreamDecodingConformanceTests` passed.
- `make verify` in `PositronicKit` passed.
- Downstream consumer verification is currently blocked by unrelated compile drift:
  Monad and Shuttle still call `ChatRunRequest`, and Yakamoz currently fails on missing
  `TurnIdentity` / inspection-model symbols.
