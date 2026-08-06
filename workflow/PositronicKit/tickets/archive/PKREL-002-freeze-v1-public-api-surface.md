# PKREL-002: Freeze the v1 Public API Surface (Break Now or Never)

**Priority:** P1
**Type:** API stability decision
**Depends on:** PKREL-001
**Blocks:** PKREL-004
**Status:** Done (2026-07-05)

### Summary

Before tagging `1.0.0`, make every breaking change we already know we want, and record an
explicit decision for every deferred one. After the tag, the public surface of `PositronicKit`,
`PKPrompt`, `PKShared`, `PKLocalEmbeddings`, and the three provider targets follows semver:
breaks require a major bump.

### Known Decision Points — RESOLVED 2026-07-05

1. **PKINT-007 construction surface — DECIDED: external registry injection.** Cross-send
   state (prompt-history registry, inspection counters) becomes injectable at construction
   (e.g. optional `TimelinePromptHistoryRegistry` init parameter, defaulting to a fresh
   instance). Purely **additive**, so implementation may land post-tag as a 1.x minor;
   Yakamoz's runtime-lifetime hoist becomes the documented pattern meanwhile. Recorded in
   PKINT-007.
2. **`ChatRunRequest` (PKINT-005) — VERIFIED CLEAN.** Single public entry point
   `run(_ request: ChatRunRequest)` (`Sources/PositronicKit/PositronicKit.swift:250`); no
   positional overloads remain. No action.
3. **`FinishReason` vocabulary (PKR-13) — VERIFIED CLEAN.** All three adapters map through
   the typed vocabulary (`OpenAIConversions.swift:110/179`, `OpenRouterClient.swift:283/628`,
   `OllamaClient.swift:257-270`). No action.
4. **Anthropic provider adapter — DECIDED: post-v1.** v1 ships OpenAI/OpenRouter/Ollama; the
   README gets a roadmap note (Claude models reachable via OpenRouter today; native
   `PKAnthropicProvider` planned as a 1.x minor — PKPOST-001). README note is pre-release
   work under this ticket.
5. **Deprecations sweep — DECIDED: remove all four pre-tag.** Delete the deprecated symbols:
   the renamed `PositronicKit` alias (`PositronicKit.swift:447`), legacy `EmbeddingService`
   protocol (`Services/Embeddings/EmbeddingService.swift:4`), `TokenEstimator` rename shim
   (`Services/LLM/TokenEstimator.swift:3`), and `WorkspaceTool` storage wrapper
   (`Models/Workspace/WorkspaceTool.swift:3`). Grep Monad/Shuttle/Yakamoz for stragglers and
   fix in the same change (downstream-sync checklist applies).

### Acceptance Criteria

- [x] Each decision point above has a written outcome (in this ticket or the referenced one).
- [x] Deprecated-symbol removal (point 5) merged, consumers grepped and green.
- [x] README roadmap note for the Anthropic adapter (point 4) merged.
- [x] All wanted breaking changes are merged before the tag; none remain "for later".
- [x] Public API of every product compiles in `PositronicKitExamples` and is exercised or
      documented (examples double as living documentation).
- [x] README states the semver policy and the post-v1 roadmap items explicitly.

### Resolution

Done in workspace changes on 2026-07-05 (`commit pending`). Removed the deprecated
`PositronicKitCore`, `EmbeddingService`, `TokenEstimator`, and `WorkspaceTool` compatibility
shims; updated the README to name the supported semver contract and post-v1 Anthropic roadmap;
grepped `Monad`, `Shuttle`, and `Yakamoz` for the removed symbols with no live consumer code
references found. Verification: `make verify` passed in `PositronicKit`, including the
DocC-validation and default-linkage gates plus the full package test suite.
