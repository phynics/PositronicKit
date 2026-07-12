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
/// Supported story map:
///
/// Setup stories
/// - prototype runtime defaults exist → `RuntimeSetupStoriesTests`
/// - provider convenience initialization (OpenAI / OpenRouter / Ollama) →
///   `RuntimeSetupStoriesTests`
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
/// - chat turn plugins trigger follow-up turns → `ExtensionStoriesTests`
/// - custom tools execute through the public facade → `ExtensionStoriesTests`
/// - workspace creators provide executable workspace-owned tools →
///   `ExtensionStoriesTests`
///
/// Example stories
/// - introductory prompt journaling flow → `IntroductoryStoriesTests`
/// - introductory runtime tool round-trip → `IntroductoryStoriesTests`
/// - README/setup/usage examples stay buildable → `ExampleUsageStoriesTests`
///
/// Supported stories that intentionally remain covered by mechanism-level suites:
/// - structured output across providers → `StructuredOutputServiceTests`
/// - tool-call recovery from provider streaming edge cases →
///   `OpenAIToolCallRecoveryTests`, `OpenRouterToolCallRecoveryTests`,
///   `ToolCallRegressionTests`, `ChatEngineTests`
/// - runtime limits / cancellation / event-stream reliability →
///   `ChatEngineTests`, `TurnBriefingBuilderCancellationTests`
/// - prompt assembly / runtime prompt history / structured compression →
///   `PromptAssemblyTests`, `TimelinePromptHistoryTests`,
///   `StructuredCompressionIntegrationTests`
/// - timeline/workspace persistence behavior → `WorkspaceAttachmentTests`,
///   `TimelineManagerTests`, `TimelineArchiverTests`
enum StoryCoverageIndex {
    // Documentation-only anchor for runtime story coverage.
}
