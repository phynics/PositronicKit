/// PositronicKit runtime story coverage index.
///
/// This file is intentionally documentation-first: it helps contributors browse the runtime-facing
/// test stories without forcing low-level contract tests into a story shape.
///
/// Primary story suites:
/// - `Stories/Setup/RuntimeSetupStoriesTests.swift`
/// - `Stories/Runtime/PublicRuntimeStoriesTests.swift`
/// - `Stories/Extensions/ExtensionStoriesTests.swift`
/// - `Stories/Examples/IntroductoryStoriesTests.swift`
/// - `Stories/Examples/ExampleUsageStoriesTests.swift`
///
/// Every suite above imports package products normally, so this directory exercises the same
/// visibility available to downstream consumers. Tests that intentionally exercise internal
/// runtime mechanisms live separately under `InternalStories/`.
///
/// Supported story map:
///
/// Setup stories
/// - prototype runtime defaults exist → `RuntimeSetupStoriesTests`
/// - invalid provider configuration fails clearly → `RuntimeSetupStoriesTests`
///
/// Public runtime stories
/// - one-turn chat through the facade → `PublicRuntimeStoriesTests`
/// - grouped persistence/runtime initialization → `PublicRuntimeStoriesTests`
/// - tool-call execution and continuation → `PublicRuntimeStoriesTests`
/// - externally submitted tool outputs resume a run → `PublicRuntimeStoriesTests`
/// - thread-managed context is used by default → `PublicRuntimeStoriesTests`
///
/// Extension stories
/// - prompt section providers inject runtime prompt content → `ExtensionStoriesTests`
/// - turn plugins trigger follow-up turns → `ExtensionStoriesTests`
/// - custom tools execute through the public facade → `ExtensionStoriesTests`
/// - workspace creators provide executable workspace-owned tools →
///   `ExtensionStoriesTests`
///
/// Example stories
/// - introductory prompt journaling flow → `IntroductoryStoriesTests`
/// - provider convenience initialization (OpenAI / Ollama) → `ExampleUsageStoriesTests`
/// - README/setup/usage examples stay buildable → `ExampleUsageStoriesTests`
///
/// Internal mechanism stories
/// - direct thread tool-registry mutation for an introductory round-trip →
///   `IntroductoryRuntimeInternalStoriesTests`
/// - direct custom pipeline-stage insertion → `CustomPipelineStageInternalStoriesTests`
///
/// Supported stories that intentionally remain covered by mechanism-level suites:
/// - structured output across providers → `StructuredOutputServiceTests`
/// - tool-call recovery from provider streaming edge cases →
///   `OpenAIToolCallRecoveryTests`, `OpenRouterToolCallRecoveryTests`,
///   `ToolCallRegressionTests`, `TurnEngineTests`
/// - facade turn-limit and required-agent preflight validation →
///   `FacadeRunValidationTests`
/// - facade one-shot parameters, structured output, timeout, and cancellation →
///   `FacadeOneShotTests`
/// - runtime cancellation / event-stream reliability → `FacadeRunValidationTests`,
///   `TurnEngineTests`, `TurnBriefingBuilderCancellationTests`
/// - prompt assembly / runtime prompt history / structured compression →
///   `PromptAssemblyTests`, `ThreadPromptHistoryTests`,
///   `StructuredCompressionIntegrationTests`
/// - thread/workspace persistence behavior → `WorkspaceAttachmentTests`,
///   `ThreadManagerTests`
enum StoryCoverageIndex {
    // Documentation-only anchor for runtime story coverage.
}
