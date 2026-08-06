# PKR-13 — `finishReason` is an untyped string with three per-adapter vocabularies

**Status:** Done — added `Sources/PKShared/SharedTypes/FinishReason.swift`, a public `FinishReason`
enum (`.stop`, `.toolCalls`, `.length`, `.contentFilter`, `.other(String)`) with a `wireValue: String`
property and a `.init(wireValue:)` parser. This is an internal normalization layer only: the existing
public `finishReason: String?` fields on `APIResponseMetadata` and `LLMStreamChoice` (in
`LLMProviderContracts.swift`) are **unchanged in type** — additive/backward-compatible scoping, per
the ticket's explicit constraint, since Yakamoz's `ChatEventReducer`/`InspectionDTOs` do a direct
`String?` assignment and `Codable` round-trip against these fields. All three adapters now route
through `FinishReason` before assigning the final string: OpenAI (`OpenAIConversions.swift`) maps its
SDK's `ChatResult.Choice.FinishReason` 1:1 (`.functionCall`/`.error` fall through to `.other(rawValue)`);
OpenRouter (`OpenRouterClient.swift`) parses its wire string via `FinishReason(wireValue:)` for both
the streaming and non-stream recovery paths; Ollama (`OllamaModels.swift`/`OllamaClient.swift`) is the
actual bug fix — added the previously-undecoded `done_reason` field to `OllamaChatResponse` and a new
`mapFinishReason` helper that preserves tool-call priority (unchanged: driven by `message.tool_calls`,
not `done_reason`) but now maps `done_reason` (e.g. `"length"`) through `FinishReason` instead of
collapsing every non-tool-call completion into `"stop"`. Truncated Ollama responses now report
`finishReason == "length"`, distinguishable from a normal `"stop"`. The two `finishReason == "tool_calls"`
comparison sites (`OpenAIClient.swift:110`, `OpenRouterClient.swift:569/585`) needed no changes since
`"tool_calls"` remains the wire value for that case. Added `Tests/PKSharedTests/FinishReasonTests.swift`
(wire-value mapping/round-trip) and four new tests in
`Tests/PositronicKitTests/Services/LLM/Providers/ProviderTransportContractTests.swift` covering Ollama's
`done_reason: "length"` truncation, normal `"stop"`, missing-`done_reason` fallback (older servers), and
tool-call priority over `done_reason`. `swift build && swift test` green (638 tests, up from 630).
**Severity:** 🟡 Low (latent cross-provider inconsistency)
**Repos:** PositronicKit (PKShared + providers)
**Source:** PositronicKit review 2026-07-02

## Problem

Each adapter normalizes finish reasons independently into a bare `String?`: OpenAI maps its SDK
enum's `rawValue` (`OpenAIConversions.swift:98`), OpenRouter passes the wire string through
(`OpenRouterClient.swift:219,273`), Ollama synthesizes only `"tool_calls"`/`"stop"`
(`OllamaClient.swift:229` — length-truncation is never represented). Today only `"tool_calls"`
is compared (`OpenAIClient.swift:110`, `OpenRouterClient.swift:569`) so nothing is broken, but
any future branching on e.g. `"length"` will behave differently per provider.

## Suggested direction

Introduce a small shared `FinishReason` enum (with `.other(String)` passthrough) in PKShared and
map all three adapters onto it; have Ollama represent truncation (`done_reason`) faithfully.
