# PKPOST-001: Ship a Native Anthropic Provider Adapter (PKAnthropicProvider)

**Priority:** P2 (post-v1 confirmed 2026-07-05 in PKREL-002; v1 README carries the roadmap note)
**Type:** Feature — new provider target
**Depends on:** PKREL-004; PKINT-001 (adapters must conform to the stream-decoding contract)
**Blocks:** None
**Status:** Done — 2026-07-05. `PKAnthropicProvider` shipped as a separate library product:
`AnthropicClient` actor (Messages API, `POST /v1/messages`, `x-api-key` + `anthropic-version`
headers) decodes the event-based SSE stream via `AnthropicStreamState` into `LLMStreamChunk`s
(text/thinking/input_json deltas; tool_use blocks get ordinal indices so downstream
accumulation matches the OpenAI-family shape); `stop_reason` maps to typed `FinishReason`;
message conversion hoists system/developer to the top-level `system` param, merges
consecutive same-role turns, and preserves tool_use/tool_result id pairing; PKR-5 retry gate
and PKR-11 sanitized error logging included. Structured output: no `response_format`
equivalent exists — `.anthropic` shares the `openAICompatible` forced-synthetic-tool branch
in `LLMServiceProtocol+StructuredOutput` (documented in code + CHANGELOG). Tests:
`AnthropicStreamDecodingTests.swift` (full-session decode, parallel tool blocks, thinking,
error event, HTTP failure, request shape) + stop-reason and message-conversion suites +
`.anthropic` added to `StructuredOutputPreparationTests`; `make verify` green at 761 tests /
142 suites, `make verify-products` green. Example (`makeConfiguredAnthropicRuntime` /
`PositronicKit(anthropicKey:)`), README support-matrix rows, and CHANGELOG Unreleased entry
added. Ships in the next tagged release (with PKSTREAM-001).

### Summary

Add a `PKAnthropicProvider` target mirroring the existing adapter pattern
(`PKOpenAIProvider` / `PKOpenRouterProvider` / `PKOllamaProvider`): Messages API client,
message/tool conversion, streaming (SSE) decoding, convenience registration APIs, and a
`PositronicKit(anthropicKey:)`-style initializer. Until this ships, Claude models are reachable
only indirectly through OpenRouter.

### Implementation Requirements

1. New library product `PKAnthropicProvider`, kept out of the core runtime target like the
   other adapters.
2. Conform to the PKINT-001 provider stream-decoding contract and pass the shared golden-wire
   conformance suite with captured Anthropic SSE chunks (event-based stream:
   `message_start` / `content_block_delta` / `message_delta` etc. — note this differs from the
   OpenAI-style chunk shape, so mapping to `LLMStreamChunk` needs its own fixtures).
3. Map Anthropic `stop_reason` values into the typed `FinishReason` vocabulary (PKR-13).
4. Tool use: convert `Tool`/`ToolParameterSchema` to Anthropic `input_schema`; preserve
   `tool_use`/`tool_result` id pairing per the PKINT-002 invariant.
5. Respect `GenerationParameters`, structured-output requests (or document non-support),
   duplicate-content retry gate parity (PKR-5), and sanitized error-body logging (PKR-11).
6. `PKTestSupport` fixtures + examples in `PositronicKitExamples`; README support-matrix row.

### Acceptance Criteria

- [ ] `swift test` covers streaming, tool calling, error mapping, and retry gating with
      captured-wire fixtures (no live network in tests).
- [ ] `make verify-products` builds the new product on Apple and Linux.
- [ ] Examples compile and demonstrate registration + a tool-calling turn.
- [ ] Docs and support matrix updated; CHANGELOG entry under `Unreleased`.
