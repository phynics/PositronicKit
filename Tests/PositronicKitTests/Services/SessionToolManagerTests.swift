import Foundation
@testable import PositronicKit
@testable import PKShared
import Testing

final class TimelineToolManagerTests {
    struct MockTool: PKShared.Tool, @unchecked Sendable {
        let callName: String
        let name: String
        let description = "A mock tool for testing"
        let requiresPermission = false
        let parametersSchema = makeEmptyObjectSchema()

        func canExecute() async -> Bool {
            true
        }

        func execute(parameters _: [String: AnyCodable]) async throws -> ToolResult {
            return .success("Executed \(name)")
        }
    }

    struct MockWorkspace: Workspace, @unchecked Sendable {
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

    @Test func initEnablesAllAvailableTools() async {
        let systemTool1 = AnyTool(MockTool(callName: "sys1", name: "System 1"))
        let systemTool2 = AnyTool(MockTool(callName: "sys2", name: "System 2"))

        let manager = TimelineToolManager(availableTools: [systemTool1, systemTool2])

        let enabled = await manager.enabledTools
        #expect(enabled.count == 2)
        #expect(enabled.contains("sys1"))
        #expect(enabled.contains("sys2"))

        let fetchedEnabled = await manager.getEnabledTools()
        #expect(fetchedEnabled.count == 2)
    }

    @Test func updateAvailableToolsAutoEnablesNewTools() async {
        let systemTool1 = AnyTool(MockTool(callName: "sys1", name: "System 1"))
        let manager = TimelineToolManager(availableTools: [systemTool1])

        // Add a new tool, and simulate one being removed
        let systemTool2 = AnyTool(MockTool(callName: "sys2", name: "System 2"))
        await manager.updateAvailableTools([systemTool2])

        let enabled = await manager.enabledTools
        #expect(enabled.count == 1) // Only sys2
        #expect(enabled.contains("sys2"))
        #expect(!(enabled.contains("sys1")))
    }

    @Test func toggleEnableDisableTools() async {
        let systemTool1 = AnyTool(MockTool(callName: "sys1", name: "System 1"))
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

    @Test func workspaceToolRegistration() async throws {
        let manager = TimelineToolManager(availableTools: [])

        let workspaceId = UUID()
        let workspaceRef = try WorkspaceReference(id: workspaceId, uri: #require(WorkspaceURI(parsing: "pk://test")), location: .runtime, originId: nil)

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

    @Test func getToolResolvesCorrectly() async throws {
        let systemTool = AnyTool(MockTool(callName: "sys1", name: "System 1"))
        let manager = TimelineToolManager(availableTools: [systemTool])

        let sysResult = await manager.getTool(id: "sys1")
        try #require(sysResult != nil)
        #expect(sysResult?.name == "System 1")

        // Workspace tool resolution
        let workspaceId = UUID()
        let def = WorkspaceToolDefinition(id: "wsTool", name: "wsTool", description: "WS", parametersSchema: [:])
        let mockWS = try MockWorkspace(
            id: workspaceId,
            reference: WorkspaceReference(id: workspaceId, uri: #require(WorkspaceURI(parsing: "pk://test")), location: .runtime, originId: nil),
            toolsToReturn: [.custom(def)]
        )
        await manager.registerWorkspace(mockWS)

        // The ID of the generic custom workspace tool wrap is something like "\(workspaceId)-\(def.name)"
        // Since we don't know the exact ID format in the test, we can just check getAvailableTools
        let available = await manager.getAvailableTools()
        let wsToolWrapper = available.first(where: { $0.name == "wsTool" })
        try #require(wsToolWrapper != nil)

        if let wsToolId = wsToolWrapper?.callName {
            let fetched = await manager.getTool(id: wsToolId)
            try #require(fetched != nil)
            #expect(fetched?.name == "wsTool")
        }
    }

    @Test func workspaceToolsHaveProvenance() async throws {
        let manager = TimelineToolManager(availableTools: [])
        let workspaceId = UUID()
        let uri = try #require(WorkspaceURI(parsing: "pk://test-workspace-prov"))
        let workspaceRef = WorkspaceReference(id: workspaceId, uri: uri, location: .runtime, originId: nil)

        let def = WorkspaceToolDefinition(id: "provTool", name: "provTool", description: "prov", parametersSchema: [:])
        let mockWS = MockWorkspace(id: workspaceId, reference: workspaceRef, toolsToReturn: [.custom(def)])

        await manager.registerWorkspace(mockWS)

        // Verify the tool has the expected provenance injected
        let available = await manager.getAvailableTools()
        let tool = available.first(where: { $0.name == "provTool" })
        try #require(tool != nil)
        #expect(tool?.provenance == .workspace(id: workspaceId, name: "pk://test-workspace-prov"))

        let fetched = try await manager.getTool(id: #require(tool?.callName))
        #expect(fetched?.provenance == .workspace(id: workspaceId, name: "pk://test-workspace-prov"))
    }

    @Test func toolProviderRegistration() async throws {
        let manager = TimelineToolManager(availableTools: [])

        struct TestProvider: ToolProviding {
            let toolProvenance: ToolProvenance = .workspace(id: UUID(), name: "Provider")
            func provideTools() async -> [AnyTool] {
                [AnyTool(MockTool(callName: "provided", name: "Provided Tool"))]
            }
        }

        let providerId = UUID()
        let provider = TestProvider()
        await manager.registerToolProvider(provider, id: providerId)

        let available = await manager.getAvailableTools()
        #expect(available.count == 1)
        #expect(available.first?.callName == "provided")
        #expect(available.first?.provenance == provider.toolProvenance)

        await manager.unregisterToolProvider(providerId)
        let availableAfter = await manager.getAvailableTools()
        #expect(availableAfter.isEmpty)
    }

    @Test func knownToolRefsResolved() async throws {
        let systemTool = AnyTool(MockTool(callName: "cat", name: "cat"))
        let manager = TimelineToolManager(availableTools: [systemTool])

        let workspaceId = UUID()
        let uri = try #require(WorkspaceURI(parsing: "pk://test-known-tool"))
        let workspaceRef = WorkspaceReference(id: workspaceId, uri: uri, location: .runtime, originId: nil)

        // Workspace declares it offers the "cat" known tool
        let mockWS = MockWorkspace(id: workspaceId, reference: workspaceRef, toolsToReturn: [.known(id: "cat")])

        await manager.registerWorkspace(mockWS)

        // The system tool should now have provenance indicating it is tied to the workspace
        let available = await manager.getAvailableTools()
        let tool = available.first(where: { $0.callName == "cat" })
        try #require(tool != nil)
        #expect(tool?.provenance == .workspace(id: workspaceId, name: "pk://test-known-tool"))

        let fetched = await manager.getTool(id: "cat")
        #expect(fetched?.provenance == .workspace(id: workspaceId, name: "pk://test-known-tool"))
    }

    @Test func multipleWorkspacesDeclaringSameKnownToolCollapseToDeterministicProvenance() async throws {
        let systemTool = AnyTool(MockTool(callName: "cat", name: "cat"))
        let manager = TimelineToolManager(availableTools: [systemTool])

        // Two workspaces, named so the lexicographic ordering of their displayName is
        // "Workspace: pk://a-workspace" < "Workspace: pk://z-workspace".
        let wsA = UUID()
        let wsB = UUID()
        let refA = WorkspaceReference(
            id: wsA,
            uri: try #require(WorkspaceURI(parsing: "pk://z-workspace")),
            location: .runtime,
            originId: nil
        )
        let refB = WorkspaceReference(
            id: wsB,
            uri: try #require(WorkspaceURI(parsing: "pk://a-workspace")),
            location: .runtime,
            originId: nil
        )

        let mockA = MockWorkspace(id: wsA, reference: refA, toolsToReturn: [.known(id: "cat")])
        let mockB = MockWorkspace(id: wsB, reference: refB, toolsToReturn: [.known(id: "cat")])

        await manager.registerWorkspace(mockA)
        await manager.registerWorkspace(mockB)

        // Both workspaces declare "cat"; provenance collapses to the single
        // lexicographically-smallest displayName (wsB's "a-workspace") so the prompt
        // label is deterministic rather than dependent on Set iteration order.
        let available = await manager.getAvailableTools()
        let tool = try #require(available.first { $0.callName == "cat" })
        #expect(tool.provenance == .workspace(id: wsB, name: "pk://a-workspace"))

        let fetched = await manager.getTool(id: "cat")
        #expect(fetched?.provenance == .workspace(id: wsB, name: "pk://a-workspace"))
    }

    @Test func getEnabledToolsAndAvailableToolsReturnDeterministicallySortedTools() async throws {
        // Seed available tools in non-sorted order to prove the returned array is sorted,
        // not just preserving the input order.
        let systemTool1 = AnyTool(MockTool(callName: "sys-zeta", name: "Zeta"))
        let systemTool2 = AnyTool(MockTool(callName: "sys-alpha", name: "Alpha"))
        let systemTool3 = AnyTool(MockTool(callName: "sys-beta", name: "Beta"))
        let manager = TimelineToolManager(availableTools: [systemTool1, systemTool2, systemTool3])

        struct TestProvider: ToolProviding {
            let toolProvenance: ToolProvenance = .workspace(id: UUID(), name: "Provider")
            func provideTools() async -> [AnyTool] {
                [AnyTool(MockTool(callName: "provided-alpha", name: "Alpha"))]
            }
        }

        let providerId = UUID()
        let provider = TestProvider()
        await manager.registerToolProvider(provider, id: providerId)

        let workspaceId = UUID()
        let workspaceRef = try WorkspaceReference(
            id: workspaceId,
            uri: #require(WorkspaceURI(parsing: "pk://test-workspace")),
            location: .runtime,
            originId: nil
        )
        let def = WorkspaceToolDefinition(
            id: "ws-omega",
            name: "Omega",
            description: "Workspace Omega",
            parametersSchema: [:]
        )
        let mockWS = MockWorkspace(id: workspaceId, reference: workspaceRef, toolsToReturn: [.custom(def)])
        await manager.registerWorkspace(mockWS)

        // System Alpha has .global provenance; provider Alpha has workspace provenance.
        // The provenance displayName is the tiebreaker, so system Alpha sorts first.
        let expectedNames = ["Alpha", "Alpha", "Beta", "Omega", "Zeta"]

        for _ in 0 ..< 10 {
            let enabled = await manager.getEnabledTools()
            let enabledNames = enabled.map(\.name)
            #expect(enabledNames == expectedNames)

            let available = await manager.getAvailableTools()
            let availableNames = available.map(\.name)
            #expect(availableNames == expectedNames)
        }

        // Verify the tiebreaker ordering between the two "Alpha" tools.
        let available = await manager.getAvailableTools()
        let alphaTools = available.filter { $0.name == "Alpha" }
        #expect(alphaTools.count == 2)
        #expect(alphaTools[0].provenance == .global)
        #expect(alphaTools[1].provenance == provider.toolProvenance)
    }

    @Test func toolsInWorkspaceReturnsOnlyThatWorkspacesCustomTools() async throws {
        let manager = TimelineToolManager(availableTools: [])

        let wsA = UUID()
        let wsB = UUID()
        let refA = WorkspaceReference(id: wsA, uri: try #require(WorkspaceURI(parsing: "pk://ws-a")), location: .runtime, originId: nil)
        let refB = WorkspaceReference(id: wsB, uri: try #require(WorkspaceURI(parsing: "pk://ws-b")), location: .runtime, originId: nil)

        let defA = WorkspaceToolDefinition(id: "toolA", name: "toolA", description: "A", parametersSchema: [:])
        let defB = WorkspaceToolDefinition(id: "toolB", name: "toolB", description: "B", parametersSchema: [:])

        await manager.registerWorkspace(MockWorkspace(id: wsA, reference: refA, toolsToReturn: [.custom(defA)]))
        await manager.registerWorkspace(MockWorkspace(id: wsB, reference: refB, toolsToReturn: [.custom(defB)]))

        let inA = await manager.tools(inWorkspace: wsA)
        #expect(inA.count == 1)
        #expect(inA.first?.name == "toolA")
        #expect(inA.first?.provenance == .workspace(id: wsA, name: "pk://ws-a"))

        let inB = await manager.tools(inWorkspace: wsB)
        #expect(inB.count == 1)
        #expect(inB.first?.name == "toolB")
        #expect(inB.first?.provenance == .workspace(id: wsB, name: "pk://ws-b"))

        // Grouping returns both workspaces, each with its own tool.
        let grouped = await manager.toolsGroupedByWorkspace()
        #expect(grouped.count == 2)
        #expect(grouped[wsA]?.count == 1)
        #expect(grouped[wsB]?.count == 1)
    }

    @Test func toolsInWorkspaceIncludesKnownSystemToolsTaggedToIt() async throws {
        let systemTool = AnyTool(MockTool(callName: "cat", name: "cat"))
        let manager = TimelineToolManager(availableTools: [systemTool])

        let wsA = UUID()
        let refA = WorkspaceReference(id: wsA, uri: try #require(WorkspaceURI(parsing: "pk://ws-a")), location: .runtime, originId: nil)
        let wsB = UUID()
        let refB = WorkspaceReference(id: wsB, uri: try #require(WorkspaceURI(parsing: "pk://ws-b")), location: .runtime, originId: nil)

        // Only wsA declares the known "cat" tool; wsB declares nothing.
        await manager.registerWorkspace(MockWorkspace(id: wsA, reference: refA, toolsToReturn: [.known(id: "cat")]))
        await manager.registerWorkspace(MockWorkspace(id: wsB, reference: refB, toolsToReturn: []))

        let inA = await manager.tools(inWorkspace: wsA)
        #expect(inA.count == 1)
        #expect(inA.first?.callName == "cat")
        #expect(inA.first?.provenance == .workspace(id: wsA, name: "pk://ws-a"))

        // wsB declared no tools -> empty.
        let inB = await manager.tools(inWorkspace: wsB)
        #expect(inB.isEmpty)

        // The flat getAvailableTools() behavior is unchanged.
        let available = await manager.getAvailableTools()
        #expect(available.count == 1)
        #expect(available.first?.callName == "cat")
    }
}
