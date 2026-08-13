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
    public actor ExamplePromptObserver: PromptObserving {
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

    /// Tier 1: a thread-free one-shot runtime.
    public static func makeOneShotRuntime() -> PositronicKit {
        PositronicKit(languageModel: UnconfiguredLLMService())
    }

    /// Tier 2: a driver for a freshly created, persisted thread.
    public static func makeThreadDriverExample() async throws -> ThreadDriver {
        let kit = makeOneShotRuntime()
        let thread = try await kit.threadManager.createThread(title: "Example Thread")
        return kit.openThread(thread.id)
    }

    /// Tier 3: the facade-owned thread manager for direct thread/workspace control.
    public static func makeThreadManagerExample() -> ThreadManager {
        makeOneShotRuntime().threadManager
    }

    /// Tier 4: an agentic runtime handle over an attached thread and agent instance.
    public static func makeAgenticRuntimeExample() async throws -> AgenticRuntime {
        let kit = makeOneShotRuntime()
        let thread = try await kit.threadManager.createThread(title: "Agentic Example")
        let agent = try await kit.agentInstanceManager.createInstance(
            from: nil,
            name: "Example Agent",
            description: "Demonstrates an attached agentic runtime."
        )
        try await kit.agentInstanceManager.attach(agentID: agent.id, to: thread.id)
        return kit.agenticRuntime(
            threadID: thread.id,
            agentInstanceID: agent.id
        )
    }

    public static func makeInspectableRuntime(inspector: any PromptObserving) -> PositronicKit {
        PositronicKit(configuration: .init(
            provider: .init(languageModel: UnconfiguredLLMService()),
            persistence: .inMemory(),
            runtime: .init(promptObserver: inspector)
        ))
    }

    public static func makeOpenAIRuntime(apiKey: String = "sk-example") -> PositronicKit {
        var openAIConfig = ProviderConfiguration.makeDefault(for: .openAI)
        openAIConfig.modelName = "gpt-4o"
        openAIConfig.apiKey = apiKey
        let config = LLMConfiguration(activeProvider: .openAI, providers: [.openAI: openAIConfig])
        let client = PKOpenAIProvider.makeClientAndRegisterStructuredOutputAdapter(configuration: config)
        let model = LLMService(
            storage: InMemoryConfigurationService(config: config),
            client: client,
            utilityClient: client,
            fastClient: client
        )
        return PositronicKit(languageModel: model)
    }

    public static func makeOllamaRuntime(model: String = "llama3") -> PositronicKit {
        var ollamaConfig = ProviderConfiguration.makeDefault(for: .ollama)
        ollamaConfig.modelName = model
        let config = LLMConfiguration(activeProvider: .ollama, providers: [.ollama: ollamaConfig])
        let client = PKOllamaProvider.makeClientAndRegisterStructuredOutputAdapter(configuration: config)
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
        var openAIConfig = ProviderConfiguration.makeDefault(for: .openAI)
        openAIConfig.apiKey = apiKey
        let configuration = LLMConfiguration(activeProvider: .openAI, providers: [.openAI: openAIConfig])
        let client = PKOpenAIProvider.makeClientAndRegisterStructuredOutputAdapter(configuration: configuration)
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
        var anthropicConfig = ProviderConfiguration.makeDefault(for: .anthropic)
        anthropicConfig.apiKey = apiKey
        let configuration = LLMConfiguration(activeProvider: .anthropic, providers: [.anthropic: anthropicConfig])
        let client = PKAnthropicProvider.makeClientAndRegisterStructuredOutputAdapter(configuration: configuration)
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
                threadPersistence: InMemoryThreadPersistence(),
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
        [ToolOutputSubmission(toolCallID: "call_123", output: "File contents...")]
    }

    /// Consumes a `ChatEvent` stream with the canonical event switch from `docs/Usage.md`.
    /// Compiles the documented handling shape — `delta`/`meta`/`completion`/`error` branches,
    /// the PKRR-011 terminal events (`.maxTurnsReached`, `.deferredForExternalTool`), and
    /// `ErrorIdentity.isBlocked` classification — against the real `ChatEvent` API, so docs
    /// drift is caught by `make verify-examples` (a step of `make verify`).
    public static func consumeChatEventStream(
        _ stream: AsyncThrowingStream<ChatEvent, Error>
    ) async throws {
        for try await event in stream {
            switch event {
            case .delta(let event):
                switch event {
                case .reasoning(let text):
                    print("\nThinking: \(text)", terminator: "")
                case .generation(let text):
                    print(text, terminator: "")
                case .audio(let delta):
                    print("\nAudio: \(delta.data.count) \(delta.format.rawValue) bytes")
                case .toolCall(let delta):
                    print("\nTool delta: \(delta.name ?? "<continuation>")")
                case .toolExecution(let toolCallID, let status):
                    print("\nTool execution [\(toolCallID)]: \(status)")
                case .sidecar(let delta):
                    print("\n[\(delta.name)] \(delta.partialText)")
                }
            case .meta(let event):
                switch event {
                case .generationContext(let metadata):
                    print("\nContext: \(metadata.files.count) files referenced")
                default:
                    // `.meta(.generationCompleted)` is deprecated and never emitted in production.
                    break
                }
            case .completion(let event):
                switch event {
                case .generationCompleted(let message, _):
                    print("\nDone: \(message.content)")
                case .completedEmpty(let finishReason):
                    print("\nCompleted empty (finishReason: \(finishReason ?? "nil"))")
                case .toolExecution(let toolCallID, let status):
                    print("\nTool completed [\(toolCallID)]: \(status)")
                case .maxTurnsReached:
                    print("\nMax turns reached — the agent did not produce a tool-free final response.")
                case .deferredForExternalTool:
                    print("\nTool calls deferred for external execution; stream paused for host-side work.")
                case .sidecarsCompleted(let completion):
                    print("\nSidecars for round \(completion.identity.roundTrip), send \(completion.identity.sendID)")
                    for result in completion.results {
                        print("\n[\(result.name)] \(result.outcome)")
                    }
                default:
                    // `.completion(.streamCompleted)` is deprecated and never emitted in production.
                    break
                }
            case .error(let event):
                switch event {
                case .toolCallError(let toolCallID, let name, let error):
                    print("\nTool call error [\(toolCallID)] for \(name): \(error)")
                case .error(let message, let identity):
                    print("\nError: \(message) (blocked: \(identity?.isBlocked ?? false))")
                case .generationCancelled:
                    print("\nGeneration cancelled.")
                }
            }
        }
    }

    public static func makeTools() -> [AnyTool] {
        [ExampleGreetingTool().toAnyTool()]
    }

    /// PKPOST-004: `ToolSource` is the canonical surface for grouping tools under a
    /// structural `ToolOrigin` (rather than passing a flat `[AnyTool]`). Conform a type,
    /// return its tools from `tools()`, and register it with a runtime's
    /// `ThreadToolRegistry` (`registerToolProvider(_:id:)`); the `resolvedTools()` extension
    /// re-stamps each tool's `.global` origin with the provider's `toolOrigin` so the
    /// prompt labels tools as belonging to this workspace/terminal.
    public static func makeWorkspaceToolProviderExample(
        workspaceID: UUID = UUID(),
        workspaceName: String = "example-workspace"
    ) -> any ToolSource {
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

    /// Tier 1 structured-output variant: a one-shot `complete(_:structuredOutput:)`
    /// call, no thread created or updated. The returned string is the raw JSON
    /// payload, decodable via `decodeStructuredOutputExample(from:)`/`StructuredOutputDecoder`.
    public static func completeStructuredOutputExample(prompt: String) async throws -> ExampleTagPayload {
        let kit = makeOneShotRuntime()
        let payload = try await kit.complete(
            prompt,
            structuredOutput: makeStructuredOutputRequest(),
            generationParameters: GenerationParameters(temperature: 0, maxTokens: 128),
            idleTimeout: 30
        )
        return try decodeStructuredOutputExample(from: payload)
    }

    /// Sidecar directives (piggy-backed requests): auxiliary generations riding the same
    /// request as a chat turn's response. `title` is nullable so the model can decline once
    /// a conversation already has one. Consume via `PositronicKit.run(_:)`:
    ///
    /// ```swift
    /// let stream = try await chat.run(.init(
    ///     threadID: id,
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

/// PKPOST-004 example `ToolSource` conformance: groups its tools under a `.workspace`
/// origin so the runtime labels them as belonging to that workspace. See
/// `PositronicKitUsageExamples.makeWorkspaceToolProviderExample`.
public struct ExampleWorkspaceToolProvider: ToolSource {
    public let toolOrigin: ToolOrigin

    public init(workspaceID: UUID, workspaceName: String) {
        toolOrigin = .workspace(id: workspaceID, name: workspaceName)
    }

    public func tools() async -> [AnyTool] {
        // Tools default to `.global` origin; the `ToolSource.resolvedTools()`
        // extension re-stamps them with this provider's `toolOrigin`.
        [ExampleGreetingTool().toAnyTool()]
    }
}
