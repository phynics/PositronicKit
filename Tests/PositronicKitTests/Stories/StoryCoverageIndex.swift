/// PositronicKit runtime story coverage index.
///
/// This file maps each runtime-facing story suite to the user-visible story it
/// covers without forcing low-level contract tests into a story shape. It is
/// gate-checked, not merely documentary: `Scripts/check-story-coverage.py`
/// (via `make verify-story-coverage`) fails when a story suite on disk is
/// missing from this map or when this map names a suite that no longer
/// exists. Keep story-suite references inside the marked map as backtick-quoted
/// basenames so the gate can parse them. The mechanism-level notes below are
/// intentionally descriptive and are not part of the story-suite inventory.
///
/// Primary story suites:
/// - `Stories/Setup/RuntimeSetupStoriesTests.swift`
/// - `Stories/Runtime/PublicRuntimeStoriesTests.swift`
/// - `Stories/Extensions/ExtensionStoriesTests.swift`
/// - `PKProviderIntegrationTests/Stories/Examples/IntroductoryStoriesTests.swift`
/// - `PKProviderIntegrationTests/Stories/Examples/ExampleUsageStoriesTests.swift`
///
/// Every suite above imports package products normally, so these directories
/// exercise the same visibility available to downstream consumers. The example
/// stories live in the provider-integration target because they construct
/// provider adapters. Tests that intentionally exercise internal runtime
/// mechanisms live separately under `InternalStories/`.
///
/// BEGIN STORY SUITE MAP
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
/// - timeline-managed context is used by default → `PublicRuntimeStoriesTests`
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
/// - direct timeline tool-registry mutation for an introductory round-trip →
///   `IntroductoryRuntimeInternalStoriesTests`
/// - direct custom pipeline-stage insertion → `CustomPipelineStageInternalStoriesTests`
/// END STORY SUITE MAP
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
///   `TurnEngineTests`
/// - prompt assembly / runtime prompt history / structured compression →
///   `PromptAssemblyTests`, `TimelinePromptHistoryTests`,
///   `StructuredCompressionIntegrationTests`
/// - timeline/workspace persistence behavior → `WorkspaceAttachmentTests`,
///   `TimelineManagerTests`
enum StoryCoverageIndex {
    // Documentation-only anchor for runtime story coverage.
}
