import Foundation
@testable import MonadCore
@testable import MonadShared
import Testing

final class TimelineToolManagerTests {
    struct MockTool: MonadShared.Tool, @unchecked Sendable {
        let id: String
        let name: String
        let description = "A mock tool for testing"
        let requiresPermission = false
        var parametersSchema: [String: AnyCodable] {
            [:]
        }

        func canExecute() async -> Bool {
            true
        }

        func execute(parameters _: [String: Any]) async throws -> ToolResult {
            return .success("Executed \(name)")
        }
    }

    struct MockWorkspace: WorkspaceProtocol, @unchecked Sendable {
        let id: UUID
        let reference: WorkspaceReference
        let toolsToReturn: [ToolReference]

        func listTools() async throws -> [ToolReference] {
            toolsToReturn
        }

        func executeTool(id _: String, parameters _: [String: AnyCodable]) async throws -> ToolResult {
            .success("Workspace tool executed")
        }

        func readFile(path _: String) async throws -> String {
            ""
        }

        func writeFile(path _: String, content _: String) async throws {}
        func listFiles(path _: String) async throws -> [String] {
            []
        }

        func deleteFile(path _: String) async throws {}
        func healthCheck() async -> Bool {
            true
        }
    }

    @Test

    func initEnablesAllAvailableTools() async {
        let systemTool1 = AnyTool(MockTool(id: "sys1", name: "System 1"))
        let systemTool2 = AnyTool(MockTool(id: "sys2", name: "System 2"))

        let manager = TimelineToolManager(availableTools: [systemTool1, systemTool2])

        let enabled = await manager.enabledTools
        #expect(enabled.count == 2)
        #expect(enabled.contains("sys1"))
        #expect(enabled.contains("sys2"))

        let fetchedEnabled = await manager.getEnabledTools()
        #expect(fetchedEnabled.count == 2)
    }

    @Test

    func updateAvailableToolsAutoEnablesNewTools() async {
        let systemTool1 = AnyTool(MockTool(id: "sys1", name: "System 1"))
        let manager = TimelineToolManager(availableTools: [systemTool1])

        // Add a new tool, and simulate one being removed
        let systemTool2 = AnyTool(MockTool(id: "sys2", name: "System 2"))
        await manager.updateAvailableTools([systemTool2])

        let enabled = await manager.enabledTools
        #expect(enabled.count == 1) // Only sys2
        #expect(enabled.contains("sys2"))
        #expect(!(enabled.contains("sys1")))
    }

    @Test

    func toggleEnableDisableTools() async {
        let systemTool1 = AnyTool(MockTool(id: "sys1", name: "System 1"))
        let manager = TimelineToolManager(availableTools: [systemTool1])

        var enabled = await manager.enabledTools
        #expect(enabled.contains("sys1"))

        await manager.disableTool(id: "sys1")
        enabled = await manager.enabledTools
        #expect(!(enabled.contains("sys1")))

        await manager.enableTool(id: "sys1")
        enabled = await manager.enabledTools
        #expect(enabled.contains("sys1"))

        await manager.toggleTool("sys1")
        enabled = await manager.enabledTools
        #expect(!(enabled.contains("sys1")))
    }

    @Test

    func workspaceToolRegistration() async throws {
        let manager = TimelineToolManager(availableTools: [])

        let workspaceId = UUID()
        let workspaceRef = try WorkspaceReference(id: workspaceId, uri: #require(WorkspaceURI(parsing: "monad://test")), hostType: .server, ownerId: nil)

        let def = WorkspaceToolDefinition(
            id: "wsTool1",
            name: "wsTool1",
            description: "A workspace tool",
            parametersSchema: ["type": AnyCodable("object")]
        )

        let mockWS = MockWorkspace(
            id: workspaceId,
            reference: workspaceRef,
            toolsToReturn: [.custom(def)]
        )

        await manager.registerWorkspace(mockWS)

        let available = await manager.getAvailableTools()
        #expect(available.count == 1)
        #expect(available.first?.name == "wsTool1")

        // Unregister
        await manager.unregisterWorkspace(workspaceId)
        let availableAfter = await manager.getAvailableTools()
        #expect(availableAfter.isEmpty)
    }

    @Test

    func getToolResolvesCorrectly() async throws {
        let systemTool = AnyTool(MockTool(id: "sys1", name: "System 1"))
        let manager = TimelineToolManager(availableTools: [systemTool])

        let sysResult = await manager.getTool(id: "sys1")
        try #require(sysResult != nil)
        #expect(sysResult?.name == "System 1")

        // Workspace tool resolution
        let workspaceId = UUID()
        let def = WorkspaceToolDefinition(id: "wsTool", name: "wsTool", description: "WS", parametersSchema: [:])
        let mockWS = try MockWorkspace(
            id: workspaceId,
            reference: WorkspaceReference(id: workspaceId, uri: #require(WorkspaceURI(parsing: "monad://test")), hostType: .server, ownerId: nil),
            toolsToReturn: [.custom(def)]
        )
        await manager.registerWorkspace(mockWS)

        // The ID of the generic custom workspace tool wrap is something like "\(workspaceId)-\(def.name)"
        // Since we don't know the exact ID format in the test, we can just check getAvailableTools
        let available = await manager.getAvailableTools()
        let wsToolWrapper = available.first(where: { $0.name == "wsTool" })
        try #require(wsToolWrapper != nil)

        if let wsToolId = wsToolWrapper?.id {
            let fetched = await manager.getTool(id: wsToolId)
            try #require(fetched != nil)
            #expect(fetched?.name == "wsTool")
        }
    }

    @Test

    func workspaceToolsHaveProvenance() async throws {
        let manager = TimelineToolManager(availableTools: [])
        let workspaceId = UUID()
        let uri = try #require(WorkspaceURI(parsing: "monad://test-workspace-prov"))
        let workspaceRef = WorkspaceReference(id: workspaceId, uri: uri, hostType: .server, ownerId: nil)

        let def = WorkspaceToolDefinition(id: "provTool", name: "provTool", description: "prov", parametersSchema: [:])
        let mockWS = MockWorkspace(id: workspaceId, reference: workspaceRef, toolsToReturn: [.custom(def)])

        await manager.registerWorkspace(mockWS)

        // Verify the tool has the expected provenance injected
        let available = await manager.getAvailableTools()
        let tool = available.first(where: { $0.name == "provTool" })
        try #require(tool != nil)
        #expect(tool?.provenance?.contains("monad://test-workspace-prov") == true)

        let fetched = try await manager.getTool(id: #require(tool?.id))
        #expect(fetched?.provenance?.contains("monad://test-workspace-prov") == true)
    }

    @Test

    func knownToolRefsResolved() async throws {
        let systemTool = AnyTool(MockTool(id: "cat", name: "cat"))
        let manager = TimelineToolManager(availableTools: [systemTool])

        let workspaceId = UUID()
        let uri = try #require(WorkspaceURI(parsing: "monad://test-known-tool"))
        let workspaceRef = WorkspaceReference(id: workspaceId, uri: uri, hostType: .server, ownerId: nil)

        // Workspace declares it offers the "cat" known tool
        let mockWS = MockWorkspace(id: workspaceId, reference: workspaceRef, toolsToReturn: [.known(id: "cat")])

        await manager.registerWorkspace(mockWS)

        // The system tool should now have provenance indicating it is tied to the workspace
        let available = await manager.getAvailableTools()
        let tool = available.first(where: { $0.id == "cat" })
        try #require(tool != nil)
        #expect(tool?.provenance == "Workspace: monad://test-known-tool")

        let fetched = await manager.getTool(id: "cat")
        #expect(fetched?.provenance == "Workspace: monad://test-known-tool")
    }
}
