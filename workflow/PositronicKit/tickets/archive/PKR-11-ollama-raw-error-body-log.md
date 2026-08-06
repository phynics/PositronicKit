# PKR-11 — Ollama logs raw unsanitized error bodies, inconsistent with other providers

**Status:** Done
**Severity:** 🟡 Low (log hygiene / redaction consistency)
**Repos:** PositronicKit (PKOllamaProvider)
**Source:** PositronicKit review 2026-07-02

## Problem

`OllamaClient.swift:113-120`: on non-2xx the collected error body (8KB-capped but **not** passed
through `ProviderHTTPFailure.sanitize`) is logged raw at `.error` level before being handed to
`ProviderHTTPFailure.makeError` (which sanitizes only the thrown error). OpenRouter/OpenAI never
log the raw body (`OpenRouterClient.swift:503-510`, `:532-538`). An Ollama-compatible proxy that
echoes request headers in error bodies could leak more than intended — and it's an inconsistency
with the YAK-37 redaction posture.

## Suggested direction

Drop the raw log line (rely on the sanitized error), or sanitize before logging, matching the
other two adapters.

## Resolution (2026-07-04)

Dropped the raw error-body log line in `OllamaClient.swift` on non-2xx responses; the sanitized
body already surfaces via `ProviderHTTPFailure.makeError`'s thrown error, matching OpenAI/OpenRouter
(neither logs the raw body).

Added a test asserting the thrown `LLMServiceError.httpError`'s `responseBody` equals
`ProviderHTTPFailure.sanitize(rawBody)` and contains no embedded CR/LF. Full suite green.
