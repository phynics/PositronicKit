import Foundation
@testable import PKContracts
import PKUtilities
@testable import PositronicKit
import Testing

/// Coverage for `UnconfiguredLLMService` non-throwing methods and health checks.
///
/// The throwing methods are already covered by `UnconfiguredLLMServiceTests`; these tests
/// cover the no-op / non-throwing paths: `isConfigured`, `configuration`, `getHealthDetails`,
/// `checkHealth`, `loadConfiguration`, `clearConfiguration`.
@Suite("UnconfiguredLLMService non-throwing methods")
struct UnconfiguredLLMServiceCoverageTests {
    private let service = UnconfiguredLLMService()

    @Test("isConfigured returns false")
    func isConfiguredIsFalse() async {
        #expect(await service.isConfigured == false)
    }

    @Test("configuration returns a minimal default config")
    func configurationReturnsMinimal() async {
        let config = await service.configuration
        #expect(config.activeProvider == .openAI)
        #expect(config.memoryContextLimit == 0)
        #expect(config.documentContextLimit == 0)
        #expect(config.version == 1)
    }

    @Test("getHealthDetails reports the unconfigured error")
    func healthDetailsReportsError() async {
        let details = await service.getHealthDetails()
        #expect(details?["error"] == "Unconfigured")
    }

    @Test("checkHealth returns .down")
    func checkHealthIsDown() async {
        #expect(await service.checkHealth() == .down)
    }

    @Test("loadConfiguration is a no-op")
    func loadConfigurationIsNoOp() async {
        await service.loadConfiguration()
        // Still unconfigured.
        #expect(await service.isConfigured == false)
    }

    @Test("clearConfiguration is a no-op")
    func clearConfigurationIsNoOp() async {
        await service.clearConfiguration()
        #expect(await service.isConfigured == false)
    }
}

/// Coverage for `ContextFile.description` and Codable.
@Suite("ContextFile")
struct ContextFileCoverageTests {

    @Test("description includes name and source")
    func descriptionFormat() {
        let file = ContextFile(name: "Welcome", content: "Hello", source: "Notes/Welcome.md")
        #expect(file.description.contains("Welcome"))
        #expect(file.description.contains("Notes/Welcome.md"))
    }

    @Test("ContextFile is Codable")
    func codable() throws {
        let file = ContextFile(name: "test", content: "body", source: "src")
        let data = try JSONEncoder().encode(file)
        let decoded = try JSONDecoder().decode(ContextFile.self, from: data)
        #expect(decoded.name == "test")
        #expect(decoded.content == "body")
        #expect(decoded.source == "src")
    }
}

/// Coverage for `WorkspaceToolWrapper` — the adapter that wraps a workspace-provided
/// tool definition to conform to the `Tool` protocol.
@Suite("WorkspaceToolWrapper")
struct WorkspaceToolWrapperCoverageTests {

    @Test("wrapper delegates callName, name, description to the definition")
    func delegatesMetadata() async throws {
        let workspace = StubWorkspace()
        let definition = WorkspaceToolDefinition(
            id: "custom_tool",
            name: "Custom Tool",
            description: "A custom tool",
            parametersSchema: [:],
            usageExample: "custom_tool --foo bar",
            requiresPermission: false
        )
        let wrapper = WorkspaceToolWrapper(workspace: workspace, definition: definition)

        #expect(wrapper.callName == "custom_tool")
        #expect(wrapper.name == "Custom Tool")
        #expect(wrapper.description == "A custom tool")
        #expect(wrapper.requiresPermission == false)
        #expect(wrapper.usageExample == "custom_tool --foo bar")
    }

    @Test("canExecute delegates to workspace.healthCheck")
    func canExecuteDelegatesToHealthCheck() async throws {
        let healthy = StubWorkspace(healthy: true)
        let definition = WorkspaceToolDefinition(
            id: "tool", name: "T", description: "D",
            parametersSchema: [:], requiresPermission: false
        )
        let wrapper = WorkspaceToolWrapper(workspace: healthy, definition: definition)
        #expect(await wrapper.canExecute() == true)

        let unhealthy = StubWorkspace(healthy: false)
        let unhealthyWrapper = WorkspaceToolWrapper(workspace: unhealthy, definition: definition)
        #expect(await unhealthyWrapper.canExecute() == false)
    }

    @Test("execute delegates to workspace and returns success on success")
    func executeReturnsSuccess() async throws {
        let workspace = StubWorkspace(toolResult: .success("done"))
        let definition = WorkspaceToolDefinition(
            id: "my_tool", name: "My Tool", description: "Does things",
            parametersSchema: [:], requiresPermission: false
        )
        let wrapper = WorkspaceToolWrapper(workspace: workspace, definition: definition)
        let result = try await wrapper.execute(parameters: ["x": .string("y")])
        #expect(result.success)
        #expect(result.output == "done")
    }

    @Test("execute returns failure when workspace returns failure")
    func executeReturnsFailure() async throws {
        let workspace = StubWorkspace(toolResult: .failure("boom"))
        let definition = WorkspaceToolDefinition(
            id: "my_tool", name: "My Tool", description: "Does things",
            parametersSchema: [:], requiresPermission: false
        )
        let wrapper = WorkspaceToolWrapper(workspace: workspace, definition: definition)
        let result = try await wrapper.execute(parameters: [:])
        #expect(!result.success)
        #expect(result.error == "boom")
    }
}

// MARK: - Stub workspace

private struct StubWorkspace: Workspace {
    let reference: WorkspaceReference
    let id: UUID
    let healthy: Bool
    let toolResult: ToolResult

    init(healthy: Bool = true, toolResult: ToolResult = .success("")) {
        self.reference = WorkspaceReference(
            uri: WorkspaceURI(host: "stub", path: "/stub"),
            location: .runtime
        )
        self.id = reference.id
        self.healthy = healthy
        self.toolResult = toolResult
    }

    func listTools() async throws -> [ToolReference] { [] }
    func executeTool(id _: String, parameters _: [String: AnyCodable]) async throws -> ToolResult { toolResult }
    func readFile(path _: String) async throws -> String { "" }
    func writeFile(path _: String, content _: String) async throws {}
    func listFiles(path _: String) async throws -> [String] { [] }
    func deleteFile(path _: String) async throws {}
    func healthCheck() async -> Bool { healthy }
}
