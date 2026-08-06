# PKR-12 — Silent invalid substitutions in provider request building

**Status:** Done
**Severity:** 🟡 Low (silent wrong-request instead of loud failure)
**Repos:** PositronicKit (providers, PKShared)
**Source:** PositronicKit review 2026-07-02

## Problem

Two places substitute invalid placeholder values instead of failing loudly:

1. **Ollama tool args → `{}`** — `OllamaModels.swift:113-120`: if `toolCall.arguments` doesn't
   decode as `[String: AnyCodable]` (e.g. a JSON array or scalar, which some models emit), it is
   silently replaced with empty arguments and sent to Ollama — wrong tool invocation instead of a
   diagnosable error. OpenAI/OpenRouter pass arguments through opaquely, so this is
   Ollama-specific.
2. **`toolCallID ?? ""`** — `OpenAIConversions.swift:39-40` (OpenRouter equivalent at
   `OpenRouterClient.swift:94-101`): a `.tool`-role `LLMMessage` with nil `toolCallID` (contract
   violation, but unenforced — the field is `String?`) sends an empty `tool_call_id`, surfacing
   only as an opaque provider 400.

## Suggested direction

Log a warning on the Ollama args-decode failure (consider preserving array/scalar args rather
than dropping to `{}`); for `toolCallID`, log/assert on nil for `.tool` role instead of
substituting an empty string.

## Resolution (2026-07-04)

**Ollama tool args:** `OllamaMessage.makeOllamaToolCall` now logs a `.warning` whenever
`toolCall.arguments` doesn't decode as `[String: AnyCodable]`. When the payload decodes as some
other JSON value (array/scalar), it's preserved under a `"_rawArguments"` sentinel key instead of
being silently dropped to `{}`; only a genuinely undecodable payload falls back to `{}` (also
logged).

**Nil toolCallID:** `OpenAIConversions.toOpenAIMessageParam` and `OpenRouterMessage.init` both log
a `.warning` when a `.tool`-role message has a nil `toolCallID` before falling back to `""`.

Added tests covering the Ollama non-object-args path and the OpenAI/OpenRouter nil-toolCallID
path (`CapturingLogHandler`-based). Full suite green (721 tests at merge time).
