# Changelog

All notable changes to PositronicKit are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project aims to follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

PositronicKit is currently **pre-1.0**. Per the stability contract in the
[README](README.md#v1-extension-point-registry), the v1 extension-point surfaces are the most
stable parts of the API, but until a tagged 1.0 release they may change with a minor version bump.
**Breaking changes to those surfaces are called out under a `Breaking` heading in each release.**

## [Unreleased]

### Added
- `RuntimeToolPolicy` controls for the default runtime tool installation policy (filesystem tools,
  timeline observation tools, and agent-gated `timeline_send`).
- Per-tool execution timeout on `ToolRouter` (`toolExecutionTimeout`), surfaced as a typed
  `ToolError.executionFailed` tool result.
- `PKLocalEmbeddings` facade with `LocalEmbeddingService`: Apple Natural Language by default, an
  opt-in Apple MiniLM path behind the `MiniLMEmbeddings` trait, and an in-process Linux MiniLM
  backend (Linux support is temporarily blocked pending native qualification).
- Configurable OpenRouter attribution headers.
- Injectable provider HTTP transports and typed classification of provider HTTP failures
  (`ProviderHTTPFailure`, including `Retry-After` parsing).
- Automatic tool-call recovery for OpenRouter and OpenAI streams.
- Manual verification Makefile targets (`make verify`, `verify-products`, `verify-minilm`) and
  pinned MiniLM model-asset checksums.
- Compile-checked PKPrompt layer examples in `PositronicKitExamples`
  (`renderLayer1ToString`, `assembleLayer2`, `journalLayer3`) that mirror the README.
- `PositronicKit.run(..., promptAssemblyLogger:)` — a public seam to enable prompt-assembly
  diagnostics (stage execution, section resolution, token-budget decisions) for a turn without
  reaching into internal assembly types.

### Changed
- **Breaking:** Renamed the public runtime facade from `PositronicKitCore` to `PositronicKit`.
  `PositronicKitCore` remains available as a deprecated typealias.
- **Breaking:** Shrunk the v1 public API surface. `ChatEngine`, `ToolRouter`, `PromptAssembler`,
  `PromptAssemblyOptions`/`PromptAssemblyContext`/`PromptAssemblyStage`, `ContextManager`, and the
  `InMemory*` stores are now internal/test-support only. Integrate through the `PositronicKit`
  facade and the documented extension protocols instead.
- Removed the `swift-dependencies` dependency from `PositronicKit` in favor of explicit
  constructor injection.
- Removed unsafe global mutable state from the provider registry; provider registration is now
  idempotent and overwrites the same registry slot.
- Structured output uses the provider's native schema format (e.g. Ollama).
- **Breaking:** Tightened the tool-routing surface. `ToolRouter` and `ToolExecutionOutcome` remain
  public (the host-owned tool execution seam), but `ParsedToolCall`, `ToolHandlingResult`,
  `ToolTurnResult`, and `ToolRouter.handlePendingToolCalls(...)` are now `package`-scoped runtime
  internals. The README extension-point registry is corrected to match.
- **Breaking:** Removed the unused no-argument `ToolRouter()` and `ChatEngine()` initializers that
  silently wired ephemeral temp-directory/in-memory state. Construct `ToolRouter` with explicit
  `timelineManager`/`messageStore`; the runtime is composed through the `PositronicKit` facade.

### Fixed
- Tool execution timeout now bounds wall-clock time even for tool bodies that ignore cooperative
  cancellation (e.g. blocking subprocesses or synchronous calls); the call returns promptly on
  timeout instead of blocking until the tool finishes.
- `UnconfiguredLLMService` now fails predictably rather than producing undefined behavior.
- Provider stream cancellation propagates correctly to the underlying request.
- Hardened filesystem tool path containment against traversal outside the workspace root.
- Corrected README/Usage documentation: the Layer 1 prompt example uses `renderToString()`, and the
  internal `PromptAssembler`/`PromptAssemblyOptions` types are no longer shown as downstream APIs.
- Renamed the stale `PositronicKitCore.docc` documentation catalog (and its landing article) to
  `PositronicKit.docc` to match the facade rename; refreshed its key-components list.

## [0.1] - 2026-05-04

### Added
- Initial release: the layered runtime (`PositronicKit`), prompt composition (`PKPrompt`), shared
  contracts (`PKShared`), provider adapters (`PKOpenAIProvider`, `PKOpenRouterProvider`,
  `PKOllamaProvider`), and `PKTestSupport`.

[Unreleased]: https://github.com/phynics/PositronicKit/compare/v0.1...HEAD
[0.1]: https://github.com/phynics/PositronicKit/releases/tag/v0.1
