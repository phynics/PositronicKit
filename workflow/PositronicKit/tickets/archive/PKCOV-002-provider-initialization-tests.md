# PKCOV-002 — Provider initialization contract tests

**Priority:** P2
**Type:** Test coverage
**Depends on:** —
**Blocks:** —
**Triage:** ready-for-agent
**Status:** Done (2026-07-09, commit `3063b30`) — added `ProviderInitializationTests.swift` (15
tests) directly constructing all four providers. Anthropic/Ollama/OpenRouter use a local
`RequestRecordingTransport: ProviderHTTPTransport` mock; OpenAI (which wraps the third-party SDK's
own `URLSession`/middleware seam rather than `ProviderHTTPTransport`) uses a custom
`RecordingOpenAIMiddleware` combined with a `NoNetworkURLProtocol` on a dedicated ephemeral
session — no real network calls anywhere. Pinned: default model/host/port/scheme/timeout/
maxRetries and explicit overrides for all four; OpenRouter `Attribution` → `HTTP-Referer`/`X-Title`
header presence/absence; Ollama's documented `http://localhost:11434` default confirmed to live at
the `PositronicKit(ollamaModel:)` convenience-init layer, not on `OllamaClient` itself;
`register()` idempotence added for Anthropic/Ollama (the ticket's stated gap) plus confirmatory
checks for OpenAI/OpenRouter. `Package.swift` gained one line (`OpenAI` product added to the test
target's dependencies) to reference `OpenAIMiddleware` directly. `swift test`: 917 tests / 158
suites green.

### Summary

The public initializers of `PKOpenAIProvider`, `PKAnthropicProvider`,
`PKOllamaProvider`, and `PKOpenRouterProvider` (and their clients' public inits) have no
direct tests — only indirect exercise via `RuntimeSetupStoriesTests` and transport
contract tests. Configuration mistakes (endpoint, model, key propagation) will reach
production. `PKFoundationModelsProvider` is already well covered (25 tests).

### Implementation Requirements

Add `ProviderInitializationTests` (one suite, or per-provider files matching existing
layout) asserting per provider:

1. Model name, endpoint/host/port/scheme, and generation-parameter arguments propagate
   into the constructed client/request configuration (use the existing transport-seam
   mocks from `ProviderTransportContractTests` to observe outgoing requests where
   direct inspection isn't possible).
2. Defaults are what the docs claim (e.g. OpenAI `gpt-4o`, Ollama
   `http://localhost:11434`, Anthropic default model/endpoint).
3. OpenRouter attribution: `applicationURL`/`applicationTitle` serialize into the
   expected headers.
4. `register()` idempotence for each provider (double-register does not crash or
   duplicate adapters).
5. Timeout/`maxRetries` parameters reach the retry policy where exposed
   (`OpenAIClient.init`).

### Acceptance Criteria

- [x] Direct construction of all four provider types under test.
- [x] Ollama coverage no longer minimal (config + streaming request shape pinned).
- [x] No network calls — transport seams/mocks only.
- [x] `make verify` green.
