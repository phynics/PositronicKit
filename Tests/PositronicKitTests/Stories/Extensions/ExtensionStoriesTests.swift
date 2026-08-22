import Foundation
import PKContracts
import PKTestSupport
import PKUtilities
import PositronicKit
import Synchronization
import Testing

@Suite("Extension stories") struct ExtensionStoriesTests {
    @Test("WorkspaceFactory can provide a custom executable workspace tool")
    func workspaceCreatingSupportsCustomWorkspaceTool() async throws {
        let creator = AcceptanceWorkspaceCreator()
        let (chat, mockLLM, mockPersistence, threadID, workspaceRoot, threads) = try await makeAcceptanceRuntime(
            workspaceCreator: creator,
            includeDefaultToolWorkspace: false
        )

        let workspaceId = UUID()
        let reference = WorkspaceReference(
            id: workspaceId,
            uri: WorkspaceURI(host: "pk-runtime", path: workspaceRoot.root.path),
            location: .runtimeThread,
            rootPath: workspaceRoot.root.path
        )
        let workspaceTool = WorkspaceToolDefinition(
            id: "workspace_echo",
            name: "workspace_echo",
            description: "Echoes a fixed workspace-owned result"
        )
        try await mockPersistence.saveWorkspace(reference)
        try await mockPersistence.addToolToWorkspace(workspaceId: workspaceId, tool: .custom(workspaceTool))
        try await threads.attachWorkspace(workspaceId, to: threadID)

        mockLLM.mockClient.nextToolCalls = [[MockToolCall(id: "call_ws", name: "workspace_echo")]]
        mockLLM.mockClient.nextResponses = ["", "Workspace tool completed"]

        let events = try await chat.threads.open(threadID).run(TurnRequest(
            threadID: threadID,
            message: "Use the attached workspace tool"
        )).collect()

        #expect(events.contains(where: {
            if case let .completion(.toolExecution(id, status)) = $0,
               case let .success(result) = status
            {
                return id == "call_ws" && result.output == "workspace:ok"
            }
            return false
        }))
        #expect(creator.createdWorkspaceIDs().contains(workspaceId))
    }

    @Test("Custom Tool is executed through the public facade tool seam")
    func customToolExecutesThroughFacade() async throws {
        let (chat, mockLLM, _, threadID, _, _) = try await makeAcceptanceRuntime()
        let tool = AcceptanceRuntimeTool()

        mockLLM.mockClient.nextToolCalls = [[
            MockToolCall(id: "call_tool", name: "acceptance_tool", arguments: #"{"value":"Berlin"}"#),
        ]]
        mockLLM.mockClient.nextResponses = ["", "Custom tool completed"]

        let events = try await chat.threads.open(threadID).run(TurnRequest(
            threadID: threadID,
            message: "Run the custom tool",
            tools: [tool.toAnyTool()]
        )).collect()

        #expect(events.contains(where: {
            if case let .completion(.toolExecution(id, status)) = $0,
               case let .success(result) = status
            {
                return id == "call_tool" && result.output == "tool:Berlin"
            }
            return false
        }))
    }

    private func makeAcceptanceRuntime(
        workspaceCreator: any WorkspaceFactory = MockWorkspaceCreator(),
        includeDefaultToolWorkspace: Bool = true
    ) async throws -> (PositronicKit, MockLLMService, MockPersistenceService, UUID, TestWorkspace, ThreadCapability) {
        let mockLLM = MockLLMService()
        let mockPersistence = MockPersistenceService()
        let workspace = TestWorkspace()

        let chat = PositronicKit(configuration: .init(provider: .init(languageModel: mockLLM), persistence: .init(
                messageStore: mockPersistence,
                threadPersistence: mockPersistence,
                workspacePersistence: mockPersistence,
                toolPersistence: mockPersistence,
                agentStore: mockPersistence,
                requestOriginStore: mockPersistence
            ), runtime: .init(
                workspaceCreator: workspaceCreator,
                workspaceRoot: workspace.root
        )))
        let threads = chat.threads
        let thread = try await threads.create(title: "Extension Acceptance")

        if includeDefaultToolWorkspace {
            let workspaceId = UUID()
            let workspaceRef = WorkspaceReference(
                id: workspaceId,
                uri: WorkspaceURI(parsing: "pk://local")!,
                location: .runtimeThread,
                originID: nil,
                rootPath: workspace.root.path
            )
            try await mockPersistence.saveWorkspace(workspaceRef)
            try await mockPersistence.addToolToWorkspace(workspaceId: workspaceId, tool: .known("acceptance_tool"))
            try await threads.attachWorkspace(workspaceId, to: thread.id)
        }
        let agent = try await chat.agents.create(name: "Extension Agent", description: "test")
        try await chat.agents.attach(agent.id, to: thread.id)

        return (chat, mockLLM, mockPersistence, thread.id, workspace, threads)
    }
}

private actor AcceptanceWorkspace: WorkspaceToolProvider, WorkspaceFileProvider {
    let reference: WorkspaceReference
    nonisolated let id: UUID

    init(reference: WorkspaceReference) {
        self.reference = reference
        id = reference.id
    }

    func listTools() async throws -> [ToolReference] {
        reference.tools
    }

    func executeTool(id: String, parameters _: [String: AnyCodable]) async throws -> ToolResult {
        guard id == "workspace_echo" else { throw WorkspaceError.toolExecutionNotSupported }
        return .success("workspace:ok")
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

private final class AcceptanceWorkspaceCreator: WorkspaceFactory, Sendable {
    private let created = Mutex<[UUID]>([])

    func create(from reference: WorkspaceReference) throws -> any WorkspaceProvider {
        created.withLock { $0.append(reference.id) }
        return AcceptanceWorkspace(reference: reference)
    }

    func createdWorkspaceIDs() -> [UUID] {
        created.withLock { $0 }
    }
}

private struct AcceptanceRuntimeTool: PKContracts.Tool, @unchecked Sendable { // swiftlint:disable:this concurrency_unchecked_sendable -- reviewed test double (see docs/Concurrency/exception-manifest.md)
    let callName = "acceptance_tool"
    let name = "acceptance_tool"
    let description = "Custom runtime tool for extension-point acceptance testing"
    let requiresPermission = false
    let parametersSchema = makeEmptyObjectSchema()

    func canExecute() async -> Bool {
        true
    }

    func execute(parameters: [String: AnyCodable]) async throws -> ToolResult {
        .success("tool:\((parameters["value"]?.value as? String) ?? "missing")")
    }
}
