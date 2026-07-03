import Foundation
import JSONSchemaBuilder
import PKOllamaProvider
import PKOpenAIProvider
import PKShared
import PositronicKit

public enum PositronicKitUsageExamples {
    public actor ExampleTurnInspector: TurnInspecting {
        public private(set) var latestTokenEstimate = 0

        public init() {}

        public func didComposeTurn(_ inspection: TurnInspection) {
            latestTokenEstimate = inspection.estimatedTokens
        }
    }

    public static func makePrototypeRuntime() -> PositronicKit {
        PositronicKit(llmService: UnconfiguredLLMService())
    }

    public static func makeInspectableRuntime(inspector: any TurnInspecting) -> PositronicKit {
        PositronicKit(
            llmService: UnconfiguredLLMService(),
            turnInspector: inspector
        )
    }

    public static func makeOpenAIRuntime(apiKey: String = "sk-example") -> PositronicKit {
        PositronicKit(openAIKey: apiKey)
    }

    public static func makeOllamaRuntime(model: String = "llama3") -> PositronicKit {
        PositronicKit(ollamaModel: model)
    }

    public static func makeConfiguredRuntime() -> PositronicKit {
        let workspaceRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("positronickit-examples", isDirectory: true)
        let runtime = PositronicKit.RuntimeConfiguration(
            workspaceRoot: workspaceRoot
        )

        return PositronicKit(
            llmService: UnconfiguredLLMService(),
            persistence: .inMemory(),
            embeddingService: NoOpEmbeddingService(),
            runtime: runtime
        )
    }

    public static func makeConfiguredOpenAIRuntime(apiKey: String = "sk-example") -> PositronicKit {
        PKOpenAIProvider.register()
        return PositronicKit(
            llmService: LLMService(configuration: .init(
                apiKey: apiKey,
                provider: .openAI
            ))
        )
    }

    public static func makeProductionRuntime() -> PositronicKit {
        let workspaceRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("positronickit-examples-production", isDirectory: true)
        let runtime = PositronicKit.RuntimeConfiguration(
            workspaceRoot: workspaceRoot
        )

        return PositronicKit(
            llmService: UnconfiguredLLMService(),
            persistence: .init(
                messageStore: InMemoryMessageStore(),
                timelinePersistence: InMemoryTimelinePersistence(),
                workspacePersistence: InMemoryWorkspacePersistence(),
                memoryStore: InMemoryMemoryStore(),
                toolPersistence: InMemoryToolPersistence(),
                agentInstanceStore: InMemoryAgentInstanceStore(),
                requestOriginStore: InMemoryRequestOriginStore()
            ),
            embeddingService: NoOpEmbeddingService(),
            runtime: runtime
        )
    }

    public static func makeToolOutputContinuation() -> [ToolOutputSubmission] {
        [ToolOutputSubmission(toolCallId: "call_123", output: "File contents...")]
    }

    public static func makeTools() -> [AnyTool] {
        [ExampleGreetingTool().toAnyTool()]
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

    /// Sidecar directives (piggy-backed requests): auxiliary generations riding the same
    /// request as a chat turn's response. `title` is nullable so the model can decline once
    /// a conversation already has one. Consume via `PositronicKit.run(sidecars:)`:
    ///
    /// ```swift
    /// let stream = try await chat.run(timelineId: id, message: text, sidecars: makeSidecarDirectives())
    /// for try await event in stream {
    ///     if let text = event.textContent { /* stream to UI */ }
    ///     if let delta = event.sidecarDelta { /* route delta.name -> delta.partialText */ }
    ///     if let results = event.sidecarResults { /* persist final title/tone per turn */ }
    /// }
    /// ```
    public static func makeSidecarDirectives() -> [SidecarDirective] {
        [
            SidecarDirective(
                name: "title",
                instruction: "A short conversation title (3-6 words). Return null if the conversation already has a good title.",
                schema: JSONString().definition(),
                streaming: .buffered
            ),
            SidecarDirective(
                name: "tone",
                instruction: "One word describing the emotional tone of this turn (e.g. \"neutral\", \"frustrated\", \"excited\").",
                schema: JSONString().definition(),
                streaming: .buffered
            ),
        ]
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

public struct ExampleGreetingTool: Tool {
    public let id = "example_greet"
    public let name = "Example Greeting"
    public let description = "Greet a user by name so the runtime can expose a simple tool."
    public let requiresPermission = false

    public init() {}

    public var parametersSchema: [String: AnyCodable] {
        ToolParameterSchema(schemaDefinition: ExampleGreetingInput.schema.definition()).schema
    }

    public func canExecute() async -> Bool {
        true
    }

    public func execute(parameters: [String: Any]) async throws -> ToolResult {
        guard let name = parameters["name"] as? String, !name.isEmpty else {
            return .failure("Missing required parameter 'name'.")
        }

        let input = ExampleGreetingInput(name: name)
        return .success("Hello, \(input.name)!")
    }
}
