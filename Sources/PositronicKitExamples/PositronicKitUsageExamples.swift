import Foundation
import struct JSONSchema.Schema
import JSONSchemaBuilder
import PKAnthropicProvider
import PKFoundationModelsProvider
import PKOllamaProvider
import PKOpenAIProvider
import PKContracts
import PKUtilities
import PositronicKit

public enum PositronicKitUsageExamples {
    public actor ExampleTurnOutcomeSink: TurnOutcomeSink {
        public private(set) var latestOutcome: TurnOutcomeRecord?

        public init() {}

        public func record(_ outcome: TurnOutcomeRecord) {
            latestOutcome = outcome
        }
    }

    public static func makePrototypeRuntime() -> PKRuntime {
        PKRuntime(languageModel: UnconfiguredLLMService())
    }

    // MARK: - Facade operation ladder

    /// Tier 1: a timeline-free one-shot runtime.
    public static func makeOneShotRuntime() -> PKRuntime {
        PKRuntime(languageModel: UnconfiguredLLMService())
    }

    /// Creates a deterministic runtime for the executable example. It performs no network I/O.
    public static func makeOfflineRuntime() -> PKRuntime {
        PKRuntime(languageModel: OfflineLLMClient())
    }

    /// Tier 2: a handle for a freshly created, persisted TimelineRecord.
    public static func makeTimelineHandleExample() async throws -> TimelineHandle {
        let kit = makeOneShotRuntime()
        return try await kit.timelines.create(title: "Example Timeline")
    }

    /// Tier 3: the narrow TimelineRecord capability value for lifecycle and attachment operations.
    public static func makeTimelineCapabilityExample() -> TimelineCapability {
        makeOneShotRuntime().timelines
    }

    /// Tier 4: a TimelineRecord handle plus an attached agent identity.
    public static func makeManagedTimelineExample() async throws -> (TimelineHandle, Agent) {
        let kit = makeOneShotRuntime()
        let agent = try await kit.agents.create(
            name: "Example Agent",
            description: "Demonstrates managed Timeline-addressed execution."
        )
        let timeline = try await kit.timelines.create(
            title: "Managed Example",
            attaching: agent.id
        )
        return (timeline, agent)
    }

    public static func makeInspectableRuntime(sink: any TurnOutcomeSink) -> PKRuntime {
        PKRuntime(configuration: .init(
            languageModel: UnconfiguredLLMService(),
            persistence: .inMemory(),
            runtime: .init(customization: .init(turnOutcomeSink: sink))
        ))
    }

    public static func makeOpenAIRuntime(apiKey: String = "sk-example") -> PKRuntime {
        let provider = PKOpenAI.makeConfiguredProvider(
            apiKey: apiKey,
            model: "gpt-4o"
        )
        return PKRuntime(provider: provider)
    }

    public static func makeOllamaRuntime(model: String = "llama3") -> PKRuntime {
        PKRuntime(provider: PKOllama.makeConfiguredProvider(model: model))
    }

    public static func makeConfiguredRuntime() -> PKRuntime {
        let workspaceRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("positronickit-examples", isDirectory: true)
        let runtime = PKRuntime.RuntimeConfiguration(
            workspaceProfile: .hostManaged(root: workspaceRoot)
        )

        return PKRuntime(configuration: .init(
            languageModel: UnconfiguredLLMService(),
            persistence: .inMemory(),
            runtime: runtime
        ))
    }

    public static func makeConfiguredOpenAIRuntime(apiKey: String = "sk-example") -> PKRuntime {
        let provider = PKOpenAI.makeConfiguredProvider(apiKey: apiKey)
        return PKRuntime(provider: provider)
    }

    /// The native Anthropic adapter uses the same configured-provider path as the other
    /// network providers.
    public static func makeConfiguredAnthropicRuntime(apiKey: String = "sk-ant-example") -> PKRuntime {
        PKRuntime(provider: PKAnthropic.makeConfiguredProvider(apiKey: apiKey))
    }

    /// Apple's on-device Foundation Models provider remains separate because its session has no
    /// API key, endpoint, or network provider configuration. It bypasses `LLMConfiguration`
    /// directly; see `FoundationModelsClient.swift` for the platform-specific behavior.
    ///
    /// OS 26 on Apple platforms: callers below it must gate the call with `#available`. Linux and
    /// other non-Apple hosts remain available through the `*` clause.
    @available(anyAppleOS 26.0, *)
    public static func makeFoundationModelsRuntime(tools: [AnyTool] = []) -> PKRuntime {
        let client = FoundationModelsClient(tools: tools.map { AnyTool($0) })
        let languageModel = LLMService(
            configuration: .default,
            clients: .init(primary: client, utility: client, fast: client)
        )
        return PKRuntime(languageModel: languageModel)
    }

    public static func makeProductionRuntime() -> PKRuntime {
        let workspaceRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("positronickit-examples-production", isDirectory: true)
        let runtime = PKRuntime.RuntimeConfiguration(
            workspaceProfile: .hostManaged(root: workspaceRoot)
        )

        return PKRuntime(configuration: .init(
            languageModel: UnconfiguredLLMService(),
            persistence: .init(
                runtimeRepository: InMemoryTimelineRuntimeRepository(),
                workspacePersistence: InMemoryWorkspacePersistence(),
                toolPersistence: InMemoryToolPersistence(),
                agentStore: InMemoryAgentStore(),
                requestOriginStore: InMemoryRequestOriginStore()
            ),
            runtime: runtime
        ))
    }

    public static func makeToolOutputContinuation() -> [ToolOutputSubmission] {
        [ToolOutputSubmission(toolCallID: "call_123", output: "File contents...")]
    }

    /// Renders the common Turn path from `docs/Usage.md` without nested event
    /// switching: stream generated text, then await one consolidated durable
    /// result. Compiles the documented `generatedText()` / `result()` shape
    /// against the real `TurnHandle` API, so docs drift is caught by
    /// `make verify-examples`.
    public static func renderCommonTurn(_ turn: TurnHandle) async throws {
        for await text in turn.generatedText() {
            print(text, terminator: "")
        }
        let result = try await turn.result()
        print("\nDone: \(result.message?.content ?? "")")
    }

    /// Consumes a `TurnEvent` stream with the canonical event switch from `docs/Usage.md`.
    /// Compiles the documented handling shape — `delta`/`completion`/`error` branches,
    /// the PKRR-011 terminal events (`.maxModelRoundsReached`, `.deferredForExternalTool`), and
    /// `ErrorIdentity.isBlocked` classification — against the real `TurnEvent` API, so docs
    /// drift is caught by `make verify-examples` (a step of `make verify`).
    public static func consumeTurnEventStream(
        _ stream: AsyncThrowingStream<TurnEvent, Error>
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
            case .completion(let event):
                switch event {
                case .generationCompleted(let message, _):
                    print("\nDone: \(message.content)")
                case .completedEmpty(let finishReason):
                    print("\nCompleted empty (finishReason: \(finishReason ?? "nil"))")
                case .toolExecution(let toolCallID, let status):
                    print("\nTool completed [\(toolCallID)]: \(status)")
                case .maxModelRoundsReached:
                    print("\nMaximum model rounds reached — the agent did not produce a tool-free final response.")
                case .deferredForExternalTool:
                    print("\nTool calls deferred for external execution; stream paused for host-side work.")
                case .sidecarsCompleted(let completion):
                    print("\nSidecars for round \(completion.identity.modelRoundIndex), send \(completion.identity.requestID)")
                    for result in completion.results {
                        print("\n[\(result.name)] \(result.outcome)")
                    }
                }
            case .error(let event):
                switch event {
                case .toolCallError(let toolCallID, let name, let error):
                    print("\nTool call error [\(toolCallID)] for \(name): \(error)")
                case .error(let message, let identity):
                    print("\nError: \(message) (blocked: \(identity?.isBlocked ?? false))")
                case .durabilityFailure(let message, let identity):
                    print("\nDurability failure: \(message) (identity: \(String(describing: identity)))")
                case .generationCancelled:
                    print("\nGeneration cancelled.")
                }
            }
        }
    }

    public static func makeTools() -> [AnyTool] {
        [AnyTool(ExampleGreetingTool())]
    }

    /// PKPOST-004: `ToolSource` is the canonical surface for grouping tools under a
    /// structural `ToolOrigin` (rather than passing a flat `[AnyTool]`). Conform a type,
    /// return its tools from `tools()`, and register it with a runtime's
    /// `TimelineToolRegistry` (`registerToolProvider(_:id:)`); the `resolvedTools()` extension
    /// re-stamps each tool's `.global` origin with the provider's `toolOrigin` so the
    /// prompt labels tools as belonging to this workspace/terminal.
    public static func makeWorkspaceToolProviderExample(
        workspaceID: UUID = UUID(),
        workspaceName: String = "example-workspace"
    ) -> any ToolSource {
        ExampleWorkspaceToolProvider(workspaceID: workspaceID, workspaceName: workspaceName)
    }

    /// Builds the raw schema used by the advanced `generate(_:structuredOutput:)` example.
    /// Prefer `completeStructuredOutputExample(prompt:)` for typed one-shot generation.
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

    /// Tier 1 structured-output variant: a typed one-shot `kit.model.generate(...)` call, with
    /// no timeline created or updated. The raw `generate(_:structuredOutput:)` request and
    /// decoder helpers above remain available for advanced callers that need direct payload control.
    public static func completeStructuredOutputExample(prompt: String) async throws -> ExampleTagPayload {
        let kit = makeOneShotRuntime()
        return try await kit.model.generate(
            ExampleTagPayload.self,
            from: prompt,
            generationParameters: GenerationParameters(temperature: 0, maxTokens: 128),
            idleTimeout: 30
        )
    }

    /// Sidecar directives (piggy-backed requests): auxiliary generations riding the same
    /// request as a turn's response. `title` is nullable so the model can decline once
    /// a timeline already has one. Consume via the canonical `TurnHandle` path:
    ///
    /// ```swift
    /// let turn = try await chat.timelines.open(id).startTurn(
    ///     text,
    ///     options: TurnOptions(sidecars: makeSidecarDirectives())
    /// )
    /// for await event in turn.events() {
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
            instruction: "A short timeline title (3-6 words). Return null if the timeline already has a good title.",
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

    /// Cadence pattern: ask for a title until the timeline gets one, then refresh
    /// every `retitleEvery` turns.
    public static func makeCadencedSidecarDirectives(
        modelRoundIndex: Int,
        hasTimelineTitle: Bool,
        retitleEvery: Int = 5
    ) -> [SidecarDirective] {
        guard modelRoundIndex > 0 else { return [] }

        var directives = [makeToneDirective()]
        let shouldRequestTitle = !hasTimelineTitle || modelRoundIndex.isMultiple(of: retitleEvery)
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

    public enum CodingKeys: String, CodingKey {
        case tags
    }

    public init(tags: [String]) {
        self.tags = tags
    }
}

@Schemable
public struct ExampleOneShotTitlePayload: Codable, Sendable, Equatable {
    public let title: String?

    public enum CodingKeys: String, CodingKey {
        case title
    }

    public init(title: String?) {
        self.title = title
    }
}

public struct ExampleGreetingTool: PKTool {
    public let callName = "example_greet"
    public let name = "Example Greeting"
    public let toolDescription = "Greet a user by name so the runtime can expose a simple tool."
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
        [AnyTool(ExampleGreetingTool())]
    }
}
