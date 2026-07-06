# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html)
for tagged releases beginning with `1.0.0`.

## [Unreleased]

### Added

- Workspace-scoped tool grouping (PKPOST-004): new `ToolProviding` protocol and structural
  `ToolProvenance` enum in `PKShared` (`global`, `workspace(id:name:)`, `terminal(id:name:)`,
  `named(String)`). `AnyTool.provenance` is now `ToolProvenance` with a one-release deprecated
  string-init bridge. `TimelineToolManager` gains `registerToolProvider(_:id:)` /
  `unregisterToolProvider(_:)` so the runtime assembles turn tools from global tools plus
  workspace/terminal providers.   `WorkspaceProtocol.executeTool(id:parameters:)` is now optional
  with a default throwing implementation; the dead stub in `Monad.LocalWorkspace` is removed
  on the consumer side (Monad commit `c69bdf2`, which adapts Monad to this `1.1.0` API — the
  `PositronicKit` default implementation supersedes the stub, so no `PositronicKit`-side removal
  was needed).
- `PKFoundationModelsProvider` (PKPOST-003): Apple's on-device Foundation Models framework as
  a provider — `FoundationModelsClient` maps `LanguageModelSession` streaming onto
  `LLMStreamChunk` via a testable session-abstraction seam, bridges PositronicKit tools into
  the framework's tool protocol (the session executes tools itself), maps
  guardrail/termination outcomes to typed `FinishReason`, and surfaces
  `SystemLanguageModel.availability` as a typed `PKError` with user-actionable guidance.
  `#if canImport(FoundationModels)`-guarded; the package builds and tests green on hosts
  without the framework, where `chatStream` throws a typed unsupported-platform error.
- `PKAnthropicProvider` (PKPOST-001): native Anthropic Messages API adapter — event-based SSE
  stream decoding (`message_start`/`content_block_delta`/`message_delta`…) mapped onto
  `LLMStreamChunk`, `stop_reason` → typed `FinishReason`, tools via `input_schema` with
  `tool_use`/`tool_result` id pairing, system messages hoisted to the top-level `system`
  param, thinking deltas surfaced, retry-gate and sanitized-error-logging parity with the
  other adapters, and a `PositronicKit(anthropicKey:)` convenience initializer. Structured
  output rides the forced synthetic-tool path (`.anthropic` shares the `openAICompatible`
  branch) since the Messages API has no `response_format`.

### Changed

- Narrowed the LLM service seam (PKARCH-004, public API refactor). The wide
  `LLMServiceProtocol` (16 requirements) is split into three focused protocols:
  - `LLMStreamClient` — streaming chat (`chatStream`, `chatStreamWithContext`) plus
    `isConfigured`/`configuration` for setup inspection.
  - `LLMConfigStore` — configuration lifecycle (`load`/`update`/`clear`/`restore`/
    `export`/`import`).
  - `LLMUtilityClient` — one-shot/utility tasks (`sendMessage`, `generateTags`,
    `generateTitle`, `evaluateRecallPerformance`, `fetchAvailableModels`).
  `LLMService` conforms to all three. `LLMServiceProtocol` is now a
  `@available(*, deprecated)` empty protocol inheriting all three plus `HealthCheckable`,
  so existing `any LLMServiceProtocol` usage still compiles with a deprecation warning.
  The structured-output, stream, and utility default-implementation extensions were
  re-targeted onto `LLMStreamClient` (and `LLMUtilityClient where Self: LLMStreamClient`
  for the utility defaults that build on `sendStructured`). `HealthCheckable` stays on
  `LLMService` directly, not on the narrow protocols. Consumers should narrow their seams
  to the smallest protocol they need (`LLMStreamClient`, `LLMConfigStore`, or
  `LLMUtilityClient`); the deprecated composite will be removed in a future release.
  Migration note: `LLMService`/`MockLLMService`/`UnconfiguredLLMService` still conform to
  `LLMServiceProtocol`, so `any LLMServiceProtocol` call sites compile unchanged (deprecation
  warnings only). `ChatEngine`, `LLMStreamingStage`, `ChatTurnPipelineBuilder`, and
  `TimelineArchiver` were narrowed to the seam they actually use.
- Deepened the ChatEngine turn-orchestration module (PKARCH-001, internal refactor — no
  public API impact). `ChatEngine` is now a thin coordinator that delegates to four focused
  internal modules behind the same seam:
  - `TurnLoopController` — the ReAct continuation loop, max-turns enforcement, and
    cancellation handling (STAB-1 partial persistence on the error path).
  - `TurnPreparer` — session preparation: saving inputs, gathering context, resolving
    session entities, and building the initial prompt snapshot.
  - `PromptSnapshotBuilder` — follow-up prompt synthesis with the incremental-string
    assembly that avoids O(n²) re-rendering (PKR-10).
  - `PartialAssistantPersistence` — STAB-1 partial-assistant persistence on stream
    failure/cancellation.
  `ChatTurnFollowUpPolicy` was already a top-level module and is unchanged. Behavior is
  preserved exactly for cancellation, partial persistence, plugin follow-up, sidecar
  validation, and prompt-history journal-diff continuity. `ChatEngine` now depends on
  `LLMStreamClient` (streaming) plus `LLMUtilityClient` (RAG tag generation in
  `TurnPreparer.fetchContext`) rather than the full `LLMServiceProtocol`.
- Filesystem tools (`ReadFileTool`, `ListDirectoryTool`, `FindFileTool`, `SearchFilesTool`,
  `SearchFileContentTool`) no longer declare a `workspaceID` schema parameter. Workspace tools
  are constructed bound to their owning workspace, so routing context is structural (provenance)
  rather than echoed per-call by the model. Historical calls with a stray `workspaceID`
  argument continue to execute.

### Fixed

- `LLMStreamingStage.handleToolCallDeltas` (PKSTREAM-001): every yielded `ToolCallDelta` now
  carries the accumulator-resolved `id` for its index — OpenAI-style continuation chunks no
  longer reach consumers with `id == nil`.

## [1.0.0] - 2026-07-05

### Added

- Transport-neutral runtime orchestration in `PositronicKit`, centered on the public
  `PositronicKit` facade plus injectable persistence, workspace, provider, and tool seams.
- Prompt composition in `PKPrompt`, including the `@PromptBuilder` DSL, prompt assembly,
  compression, render projection, and `PromptJournal` for stable-prefix journaling workflows.
- Shared contracts in `PKShared`, including LLM/provider request and stream types, tool
  contracts, structured-output helpers, logging utilities, and common error surfaces.
- `PKLocalEmbeddings` for platform-local embeddings:
  Apple Natural Language by default on Apple platforms and the host-provisioned MiniLM bridge on
  Linux or Apple builds using the `MiniLMEmbeddings` trait.
- Provider adapters for OpenAI (`PKOpenAIProvider`), OpenRouter (`PKOpenRouterProvider`), and
  Ollama (`PKOllamaProvider`), including registration APIs and convenience runtime initializers.
- `PKTestSupport` as a reusable test-support library product for downstream runtimes.
- `PositronicKitExamples` as compiling living documentation for prompt composition, runtime
  setup, structured output, tool execution, and sidecar directives.
- Sidecar directives for piggy-backed auxiliary generations on a single model turn.
- `ChatRunRequest` as the single public request surface for chat turns.

### Highlights

- Prompt DSL plus journaling support that scales from string rendering to structured assembly and
  stable-prefix prompt history management.
- ChatEngine-backed turn pipeline with explicit runtime seams for plugins, section providers,
  persistence, workspaces, and tool routing.
- Structured output support across the shared provider contracts and example flows.
- Tool routing with approval-friendly host seams, timeline/workspace-aware resolution, and
  provider-history validation before dispatch.
- Local embeddings with clear backend ownership and published platform support constraints.

### Support Matrix

| Product | Apple Platforms | Linux | Notes |
|---------|-----------------|-------|-------|
| `PositronicKit`, `PKPrompt`, `PKShared` | Supported | Supported | Core portable modules. |
| `PKLocalEmbeddings` | Supported | Supported | Apple defaults to Natural Language; Linux uses MiniLM; Apple MiniLM is trait-gated. |
| `PKOpenAIProvider`, `PKOpenRouterProvider`, `PKOllamaProvider` | Supported | Supported | Optional concrete provider adapters. |
| `PKTestSupport`, `PositronicKitExamples` | Supported | Supported | Verified through the package graph and example builds. |

### Module Map

- `PositronicKit`: runtime orchestration, chat lifecycle, timeline/workspace management, tool
  routing, runtime extension points.
- `PKPrompt`: prompt DSL, assembly, rendering, compression, journaling.
- `PKShared`: API models, tool and provider contracts, structured-output utilities, shared
  logging and errors.
- `PKLocalEmbeddings`: local embedding facade over Apple Natural Language or MiniLM.
- `PKOpenAIProvider`, `PKOpenRouterProvider`, `PKOllamaProvider`: optional concrete provider
  adapters and registration helpers.
- `PKTestSupport`: reusable mocks, fixtures, and runtime builders for tests.
- `PositronicKitExamples`: executable examples that mirror supported public usage.

### Known Limitations

- No native Anthropic adapter yet. Claude-family models are currently reachable through
  OpenRouter; `PKAnthropicProvider` is planned as a post-v1 minor.
- `PKINT-003` is closed as hardening coverage, but its release-blocker sibling tickets remain the
  actual v1 correctness gate for release mechanics.
- `PKINT-007` is intentionally deferred to a post-v1 additive release: consumers that rebuild
  `PositronicKit` per send must continue sharing their prompt-history registry explicitly until
  the supported registry-injection API lands.
- Apple Natural Language and MiniLM vectors are not interchangeable and must not share an index.

### Changed

- The v1 public API freeze removes deprecated compatibility shims before tagging:
  `PositronicKitCore`, the legacy `EmbeddingService` protocol, the old `TokenEstimator` re-export,
  and the `WorkspaceTool` storage wrapper.
- The README now defines the semver policy for tagged releases and names the post-v1 Anthropic
  roadmap explicitly.

### Migration Notes

- Replace any `PositronicKitCore` references with `PositronicKit`.
- Replace the removed `EmbeddingService` protocol with `EmbeddingServiceProtocol`.
- Replace `PositronicKit.TokenEstimator` imports with `PKShared.TokenEstimator`.
- Replace `WorkspaceTool` storage-wrapper usage with `ToolReference` and
  `WorkspaceToolDefinition`.

### Release Notes

PositronicKit `1.0.0` establishes the semver baseline for the shared agent runtime used by
Monad, Shuttle, and Yakamoz. The release bundles the transport-neutral runtime facade, the
`PKPrompt` composition system, provider adapters for OpenAI/OpenRouter/Ollama, local embeddings,
structured output, sidecar directives, and the `PKTestSupport` / examples products into one
documented compatibility line.

Highlights for downstream consumers:

- adopt `ChatRunRequest` as the stable request surface;
- compose prompts through `PKPrompt` and `PromptJournal`;
- rely on provider-history validation and tool-routing seams instead of host-specific forks;
- choose Apple Natural Language or MiniLM explicitly when owning vector stores.

Known caveats for the tag:

- Anthropic is still OpenRouter-only until `PKAnthropicProvider` lands;
- per-send runtime reconstruction still requires a shared prompt-history registry until the
  `PKINT-007` additive follow-up ships;
- vector stores must stay backend-specific because Apple NL and MiniLM embeddings are incompatible.
