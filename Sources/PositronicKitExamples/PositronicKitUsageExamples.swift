import Foundation
import JSONSchemaBuilder
import PositronicKit
import PKShared

public enum PositronicKitUsageExamples {
    public static func makePrototypeRuntime() -> PositronicKitCore {
        PositronicKitCore(llmService: UnconfiguredLLMService())
    }

    public static func makeConfiguredRuntime() -> PositronicKitCore {
        let workspaceRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("positronickit-examples", isDirectory: true)

        return PositronicKitCore(
            llmService: UnconfiguredLLMService(),
            messageStore: InMemoryMessageStore(),
            timelineManager: TimelineManager(workspaceRoot: workspaceRoot),
            toolRouter: ToolRouter(),
            agentInstanceStore: InMemoryAgentInstanceStore(),
            requestOriginStore: InMemoryRequestOriginStore(),
            timelinePersistence: InMemoryTimelinePersistence(),
            workspacePersistence: InMemoryWorkspacePersistence(),
            memoryStore: InMemoryMemoryStore(),
            toolPersistence: InMemoryToolPersistence(),
            agentTemplateStore: InMemoryAgentTemplateStore(),
            embeddingService: NoOpEmbeddingService(),
            workspaceRoot: workspaceRoot
        )
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
