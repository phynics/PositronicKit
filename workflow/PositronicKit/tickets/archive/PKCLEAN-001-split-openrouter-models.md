# PKCLEAN-001 — Split OpenRouterClient.swift model layer into OpenRouterModels.swift

**Priority:** P3
**Type:** Refactor (file split, no API change)
**Depends on:** —
**Blocks:** —
**Triage:** ready-for-agent
**Status:** Done (2026-07-09, commit `9bd7227`, merged `427f773`) — pure file move:
`OpenRouterClient.swift` now 418 lines (actor + `Attribution`), new `OpenRouterModels.swift`
holds the 14 model types + stream-chunk extension (296 lines). No public API change.
`swift build`/`swift test` green (926 tests / 159 suites at merge time). CHANGELOG updated.

### Summary

`Sources/PKOpenRouterProvider/OpenRouterClient.swift` is 709 lines — the largest source file
in the package. The first ~300 lines are 14 private `Codable` request/response model types;
the `OpenRouterClient` actor itself starts at line 302. Extract the model layer into a sibling
`OpenRouterModels.swift` so the client file holds only the actor, mirroring the existing
convention in `PKOllamaProvider` (`OllamaModels.swift` + `OllamaClient.swift`) and
`PKAnthropicProvider` (`AnthropicModels.swift` + `AnthropicClient.swift`).

### Current Problem

`Sources/PKOpenRouterProvider/OpenRouterClient.swift` mixes two concerns:

- **Data models (lines 11–300):** `OpenRouterModelsResponse`, `OpenRouterChatResponse`,
  `OpenRouterUsage`, `OpenRouterChatRequest`, `OpenRouterMessage`, `OpenRouterToolCall`,
  `OpenRouterToolCallFunction`, `OpenRouterTool`, `OpenRouterToolDefinition`,
  `OpenRouterToolChoice`, `OpenRouterResponseFormat`, `OpenRouterResponseSchema`,
  `OpenRouterStreamOptions`, `OpenRouterStreamChunk` (+ its `private extension` at line 260).
- **Client actor (line 302):** `public actor OpenRouterClient: LLMClientProtocol` with `Attribution`,
  `init`, `chatStream`, `sendMessage`, `fetchAvailableModels`.

The sibling providers already separate models from client; `PKOpenRouterProvider` is the
inconsistent outlier (3 files: `OpenRouterClient.swift`, `OpenRouterStructuredOutputAdapter.swift`,
`PKOpenRouterProvider.swift` — no `OpenRouterModels.swift`).

### Implementation Requirements

1. Create `Sources/PKOpenRouterProvider/OpenRouterModels.swift`.
2. Move the 14 model types + the `OpenRouterStreamChunk` private extension (lines 11–300) into it,
   preserving their exact access levels (`private`/internal) and `Codable`/`Sendable` conformances.
3. Leave `OpenRouterClient` (line 302 onward) in `OpenRouterClient.swift`.
4. No logic changes — pure file move. Types that are currently `private` stay `private` (file-scoped
   is fine because the actor lives in the same module; if any model is `private` and only used by the
   actor, it must become `internal` so the actor in another file can see it — check each).
5. Update `CHANGELOG.md` under `Unreleased` → `Changed` with a one-line internal-refactor note
   (no public API change).

### Acceptance Criteria

- [ ] `OpenRouterClient.swift` is ~400 lines (actor + `Attribution` only).
- [ ] `OpenRouterModels.swift` holds the 14 model types + the stream-chunk extension.
- [ ] `swift build` green.
- [ ] `swift test` green (880 tests / 155 suites baseline).
- [ ] `make verify-products` builds `PKOpenRouterProvider`.
- [ ] No public API change (diff is a pure move).
- [ ] `CHANGELOG.md` `Unreleased` → `Changed` updated.
