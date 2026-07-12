import Foundation
import struct JSONSchema.Schema
import JSONSchemaBuilder
import PKAnthropicProvider
import PKFoundationModelsProvider
import PKOllamaProvider
import PKOpenAIProvider
import PKShared
import PKUtilities
import PositronicKit

public enum PositronicKitUsageExamples {
    public actor ExamplePromptInspector: PromptInspecting {
        public private(set) var latestTokenEstimate = 0

        public init() {}

        public func didComposePrompt(_ inspection: PromptInspection) {
            latestTokenEstimate = inspection.estimatedTokens
        }
    }

    public static func makePrototypeRuntime() -> PositronicKit {
        PositronicKit(languageModel: UnconfiguredLLMService())
    }

    // MARK: - Facade operation ladder

    /// Tier 1: a timeline-free one-shot runtime.
    public static func makeOneShotRuntime() -> PositronicKit {
        PositronicKit(languageModel: UnconfiguredLLMService())
    }

    /// Tier 2: a persisted conversation cursor, created through the facade.
    public static func makeConversationExample() async throws -> Conversation {
        try await makeOneShotRuntime().newConversation(title: "Example Conversation")
    }

    /// Tier 3: the facade-owned timeline manager for direct timeline/workspace control.
    public static func makeTimelineManagerExample() -> TimelineManager {
        makeOneShotRuntime().timelineManager
    }

    /// Tier 4: an agentic runtime handle over a timeline and agent instance.
    public static func makeAgenticRuntimeExample() -> AgenticRuntime {
        makeOneShotRuntime().agenticRuntime(
            timelineId: UUID(),
            agentInstanceId: UUID()
        )
    }

    public static func makeInspectableRuntime(inspector: any PromptInspecting) -> PositronicKit {
        PositronicKit(configuration: .init(
            provider: .init(languageModel: UnconfiguredLLMService()),
            persistence: .inMemory(),
            runtime: .init(promptInspector: inspector)
        ))
    }

    public static func makeOpenAIRuntime(apiKey: String = "sk-example") -> PositronicKit {
        let config = LLMConfiguration(modelName: "gpt-4o", apiKey: apiKey, provider: .openAI)
        let client = PKOpenAIProvider.makeClient(configuration: config)
        let model = LLMService(
            storage: InMemoryConfigurationService(config: config),
            client: client,
            utilityClient: client,
            fastClient: client
        )
        return PositronicKit(languageModel: model)
    }

    public static func makeOllamaRuntime(model: String = "llama3") -> PositronicKit {
        let config = LLMConfiguration(modelName: model, provider: .ollama)
        let client = PKOllamaProvider.makeClient(configuration: config)
        let languageModel = LLMService(
            storage: InMemoryConfigurationService(config: config),
            client: client,
            utilityClient: client,
            fastClient: client
        )
        return PositronicKit(languageModel: languageModel)
    }

    public static func makeConfiguredRuntime() -> PositronicKit {
        let workspaceRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("positronickit-examples", isDirectory: true)
        let runtime = PositronicKit.RuntimeConfiguration(
            workspaceRoot: workspaceRoot
        )

        return PositronicKit(configuration: .init(
            provider: .init(languageModel: UnconfiguredLLMService(), embeddingService: NoOpEmbeddingService()),
            persistence: .inMemory(),
            runtime: runtime
        ))
    }

    public static func makeConfiguredOpenAIRuntime(apiKey: String = "sk-example") -> PositronicKit {
        let configuration = LLMConfiguration(apiKey: apiKey, provider: .openAI)
        let client = PKOpenAIProvider.makeClient(configuration: configuration)
        let languageModel = LLMService(
            storage: InMemoryConfigurationService(config: configuration),
            client: client,
            utilityClient: client,
            fastClient: client
        )
        return PositronicKit(configuration: .init(
            provider: .init(languageModel: languageModel),
            persistence: .inMemory()
        ))
    }

    /// PKPOST-001: the native Anthropic adapter registers exactly like the other providers;
    /// `PositronicKit(anthropicKey:)` wraps registration + configuration in one call.
    public static func makeConfiguredAnthropicRuntime(apiKey: String = "sk-ant-example") -> PositronicKit {
        let configuration = LLMConfiguration(apiKey: apiKey, provider: .anthropic)
        let client = PKAnthropicProvider.makeClient(configuration: configuration)
        let languageModel = LLMService(
            storage: InMemoryConfigurationService(config: configuration),
            client: client,
            utilityClient: client,
            fastClient: client
        )
        return PositronicKit(languageModel: languageModel)
    }

    /// PKPOST-003: Apple's on-device Foundation Models provider — no API key, no network.
    /// `PositronicKit(foundationModelsTools:)` wraps `FoundationModelsClient` construction (with
    /// tools bridged into the session up front, since the framework executes tools itself while
    /// producing a response) directly, bypassing `ExternalLLMProviderRegistry`/`LLMConfiguration`
    /// entirely — see `PKFoundationModelsProvider.swift` for why that registry shape doesn't fit
    /// an on-device session. Compiles unconditionally; on hosts without the `FoundationModels`
    /// framework (or pre-26 macOS), the resulting runtime's `chatStream` throws
    /// `FoundationModelsPlatformError.unsupportedPlatform` rather than crashing.
    public static func makeFoundationModelsRuntime(tools: [AnyTool] = []) -> PositronicKit {
        let client = FoundationModelsClient(tools: tools.map { $0.toAnyTool() })
        let languageModel = LLMService(
            storage: InMemoryConfigurationService(config: .default),
            client: client,
            utilityClient: client,
            fastClient: client
        )
        return PositronicKit(languageModel: languageModel)
    }

    public static func makeProductionRuntime() -> PositronicKit {
        let workspaceRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("positronickit-examples-production", isDirectory: true)
        let runtime = PositronicKit.RuntimeConfiguration(
            workspaceRoot: workspaceRoot
        )

        return PositronicKit(configuration: .init(
            provider: .init(languageModel: UnconfiguredLLMService(), embeddingService: NoOpEmbeddingService()),
            persistence: .init(
                messageStore: InMemoryMessageStore(),
                timelinePersistence: InMemoryTimelinePersistence(),
                workspacePersistence: InMemoryWorkspacePersistence(),
                memoryStore: InMemoryMemoryStore(),
                toolPersistence: InMemoryToolPersistence(),
                agentInstanceStore: InMemoryAgentInstanceStore(),
                requestOriginStore: InMemoryRequestOriginStore()
            ),
            runtime: runtime
        ))
    }

    public static func makeToolOutputContinuation() -> [ToolOutputSubmission] {
        [ToolOutputSubmission(toolCallId: "call_123", output: "File contents...")]
    }

    public static func makeTools() -> [AnyTool] {
        [ExampleGreetingTool().toAnyTool()]
    }

    /// PKPOST-004: `ToolProviding` is the canonical surface for grouping tools under a
    /// structural `ToolProvenance` (rather than passing a flat `[AnyTool]`). Conform a type,
    /// return its tools from `provideTools()`, and register it with a runtime's
    /// `TimelineToolManager` (`registerToolProvider(_:id:)`); the `resolvedTools()` extension
    /// re-stamps each tool's `.global` provenance with the provider's `toolProvenance` so the
    /// prompt labels tools as belonging to this workspace/terminal.
    public static func makeWorkspaceToolProviderExample(
        workspaceID: UUID = UUID(),
        workspaceName: String = "example-workspace"
    ) -> any ToolProviding {
        ExampleWorkspaceToolProvider(workspaceID: workspaceID, workspaceName: workspaceName)
    }

    public static func makeStructuredOutputSchema() -> StructuredOutputSchema {
        StructuredOutputSchema(
            name: "tag_payload",
            description: "A structured list of tags extracted from user input.",
            schema: ExampleTagPayload.schema.definition()
        )
    }

    public static func makeStructuredOutputRequest() -> StructuredOutputRequest {
        .jsonSchema(makeStructuredOutputSchema())
    }

    public static func decodeStructuredOutputExample(from payload: String) throws -> ExampleTagPayload {
        try StructuredOutputDecoder.decode(ExampleTagPayload.self, from: payload)
    }

    /// Sidecar directives (piggy-backed requests): auxiliary generations riding the same
    /// request as a chat turn's response. `title` is nullable so the model can decline once
    /// a conversation already has one. Consume via `PositronicKit.run(_:)`:
    ///
    /// ```swift
    /// let stream = try await chat.run(.init(
    ///     timelineId: id,
    ///     message: text,
    ///     sidecars: makeSidecarDirectives()
    /// ))
    /// for try await event in stream {
    ///     if let text = event.textContent { /* stream to UI */ }
    ///     if let delta = event.sidecarDelta { /* route delta.name -> delta.partialText */ }
    ///     if let results = event.sidecarResults { /* persist final title/tone per turn */ }
    /// }
    /// ```
    public static func makeSidecarDirectives() -> [SidecarDirective] {
        [
            makeDeclinableTitleDirective(),
            makeToneDirective(),
        ]
    }

    /// Declinable sidecar pattern: a nullable field lets the model say "no update needed"
    /// without turning that into an error.
    public static func makeDeclinableTitleDirective() -> SidecarDirective {
        SidecarDirective(
            name: "title",
            instruction: "A short conversation title (3-6 words). Return null if the conversation already has a good title.",
            schema: try! Schema(instance: #"{"type":["string","null"]}"#),
            streaming: .buffered
        )
    }

    /// Example of a constrained tone field expressed as a small enum-like string schema.
    public static func makeToneDirective() -> SidecarDirective {
        SidecarDirective(
            name: "tone",
            instruction: "One word describing the emotional tone of this turn.",
            schema: try! Schema(instance: #"{"type":"string","enum":["neutral","frustrated","excited"]}"#),
            streaming: .buffered
        )
    }

    /// Cadence pattern: ask for a title until the conversation gets one, then refresh
    /// every `retitleEvery` turns.
    public static func makeCadencedSidecarDirectives(
        turnIndex: Int,
        hasConversationTitle: Bool,
        retitleEvery: Int = 5
    ) -> [SidecarDirective] {
        guard turnIndex > 0 else { return [] }

        var directives = [makeToneDirective()]
        let shouldRequestTitle = !hasConversationTitle || turnIndex.isMultiple(of: retitleEvery)
        if shouldRequestTitle {
            directives.insert(makeDeclinableTitleDirective(), at: 0)
        }
        return directives
    }

    public static func makeOneShotTitleStructuredOutputRequest() -> StructuredOutputRequest {
        .jsonSchema(StructuredOutputSchema(
            name: "title_payload",
            description: "A declinable title payload reused outside a sidecar turn.",
            schema: ExampleOneShotTitlePayload.schema.definition()
        ))
    }

    public static func decodeOneShotTitlePayload(from payload: String) throws -> ExampleOneShotTitlePayload {
        try StructuredOutputDecoder.decode(ExampleOneShotTitlePayload.self, from: payload)
    }
}

@Schemable
public struct ExampleGreetingInput: Codable, Sendable {
    public let name: String

    public init(name: String) {
        self.name = name
    }
}

@Schemable
public struct ExampleTagPayload: Codable, Sendable, Equatable {
    public let tags: [String]

    public init(tags: [String]) {
        self.tags = tags
    }
}

@Schemable
public struct ExampleOneShotTitlePayload: Codable, Sendable, Equatable {
    public let title: String?

    public init(title: String?) {
        self.title = title
    }
}

public struct ExampleGreetingTool: Tool {
    public let callName = "example_greet"
    public let name = "Example Greeting"
    public let description = "Greet a user by name so the runtime can expose a simple tool."
    public let requiresPermission = false

    public init() {}

    public var parametersSchema: Schema {
        ToolParameterSchema(schemaDefinition: ExampleGreetingInput.schema.definition()).schemaDefinition
    }

    public func canExecute() async -> Bool {
        true
    }

    public func execute(parameters: [String: AnyCodable]) async throws -> ToolResult {
        guard let name = parameters["name"]?.value as? String, !name.isEmpty else {
            return .failure("Missing required parameter 'name'.")
        }

        let input = ExampleGreetingInput(name: name)
        return .success("Hello, \(input.name)!")
    }
}

/// PKPOST-004 example `ToolProviding` conformance: groups its tools under a `.workspace`
/// provenance so the runtime labels them as belonging to that workspace. See
/// `PositronicKitUsageExamples.makeWorkspaceToolProviderExample`.
public struct ExampleWorkspaceToolProvider: ToolProviding {
    public let toolProvenance: ToolProvenance

    public init(workspaceID: UUID, workspaceName: String) {
        toolProvenance = .workspace(id: workspaceID, name: workspaceName)
    }

    public func provideTools() async -> [AnyTool] {
        // Tools default to `.global` provenance; the `ToolProviding.resolvedTools()`
        // extension re-stamps them with this provider's `toolProvenance`.
        [ExampleGreetingTool().toAnyTool()]
    }
}
