---
Priority: P1
Type: Code duplication
Depends: —
Blocks: —
Triage: ready-for-agent
Status: Done
Confidence: High — verified 7+ instances of each pattern
Owner: —
Effort: M
Review: Code review 2026-07-29
Pinned revision: a354632
Resolution: Completed 2026-07-29. Added shared HTTP response/status/error helpers and SSE data
extraction, and migrated OpenRouter, Anthropic, and Ollama clients. Model listing remained
provider-specific for type safety. Full verification passed with 1610 tests in 238 suites.
---

# PKCR-004 — Extract HTTP helpers: response guards, model listing, SSE parsing

## Summary

Three HTTP-related patterns are duplicated across the OpenRouter, Anthropic, and Ollama provider clients:

1. **HTTP response-type guard + status guard** — `guard let httpResponse = response as? HTTPURLResponse` + `guard (200...299).contains(...)` appears 7 times each.
2. **`fetchAvailableModels`** — 3 near-identical GET/status-check/decode/map/sort implementations.
3. **SSE `data: ` line parsing** — 2 near-identical trim/prefix/drop/`[DONE]`/decode implementations.

## Current problem

- Response-type + status guards:
  - `OpenRouterClient.swift:234,263,387` — 3 instances
  - `AnthropicClient.swift:139,307` — 2 instances
  - `OllamaClient.swift:113,329` — 2 instances
- `fetchAvailableModels`:
  - `OpenRouterClient.swift:378-399`
  - `AnthropicClient.swift:297-319`
  - `OllamaClient.swift:317-342`
- SSE line parsing:
  - `OpenRouterClient.swift:276-310` (`processSSELine`)
  - `AnthropicClient.swift:166-200` (`processSSELine`)
- `sanitize(String(data: data, encoding: .utf8) ?? "")` chain — 4 instances across the same files.

## Implementation requirements

1. Add `func ensureHTTPResponse(_ response: URLResponse, provider: String) throws -> HTTPURLResponse` in `PKUtilities`.
2. Add `func ensureSuccessStatus(_ response: HTTPURLResponse, provider: String, body: Data) throws` in `PKUtilities` (handles the sanitize chain internally).
3. Add `func extractSSEData(from line: String) -> Data?` in `PKUtilities` (handles trim/prefix/drop/`[DONE]`/data conversion).
4. Optionally: add a shared `HTTPModelLister` helper or default `fetchAvailableModels` extension that takes URL, headers, and decode type.
5. Update all 3 provider clients to use the shared helpers.
6. Update `CHANGELOG.md` under `Unreleased`.

## Acceptance criteria

- [ ] `ensureHTTPResponse` and `ensureSuccessStatus` helpers added and used at all 7 guard sites.
- [ ] `extractSSEData` helper added and used in both `processSSELine` implementations.
- [ ] `fetchAvailableModels` deduplicated (shared helper or default extension).
- [ ] `sanitize(String(data:...))` chain replaced with `ensureSuccessStatus` overload.
- [ ] `swift build` succeeds.
- [ ] `swift test` passes (1598+ tests).
- [ ] `CHANGELOG.md` updated.
