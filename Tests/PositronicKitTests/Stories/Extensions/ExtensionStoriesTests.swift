import Foundation
import PKPrompt
@testable import PKShared
import PKTestSupport
@testable import PositronicKit
import Testing

@Suite("Extension stories") struct ExtensionStoriesTests {
    @Test("PromptSectionProviding injects custom prompt content into the assembled prompt")
    func promptSectionProviderInjectsPromptContent() async throws {
        let provider = AcceptancePromptSectionProvider()
        let (chat, mockLLM, _, timelineId, _, _) = try await makeAcceptanceRuntime(
            sectionProviders: [provider]
        )
        mockLLM.mockClient.nextResponse = "Saw extension section"

        _ = try await chat.run(
            timelineId: timelineId,
            message: "Use extension prompt"
        ).collect()

        let promptText = mockLLM.mockClient.lastMessages.map(\.content).joined(separator: "\n")
        #expect(promptText.contains("EXTENSION_MARKER: provider injected context"))
    }

    @Test("ChatTurnPlugin can trigger a follow-up turn with injected messages")
    func chatTurnPluginTriggersFollowUpTurn() async throws {
        let plugin = AcceptanceChatTurnPlugin()
        let (baseChat, mockLLM, mockPersistence, timelineId, _, _) = try await makeAcceptanceRuntime()
        let chat = baseChat.addPlugin(plugin)

        mockLLM.mockClient.nextResponses = ["First reply", "Second reply"]

        let events = try await chat.run(
            timelineId: timelineId,
            message: "Start plugin flow"
        ).collect()

        let completedMessages = events.compactMap(\.completedMessage).map(\.message.content)
        #expect(completedMessages == ["First reply", "Second reply"])

        let pluginInputs = await plugin.seenResponses()
        #expect(pluginInputs == ["First reply", "First replySecond reply"])

        let persistedMessages = try await mockPersistence.fetchMessages(for: timelineId)
        let assistantReplies = persistedMessages.filter { $0.role == "assistant" }.map(\.content)
        #expect(assistantReplies == ["First reply", "Second reply"])
    }

    @Test("WorkspaceCreating can provide a custom executable workspace tool")
    func workspaceCreatingSupportsCustomWorkspaceTool() async throws {
        let creator = AcceptanceWorkspaceCreator()
        let (chat, mockLLM, mockPersistence, timelineId, workspaceRoot, timelineManager) = try await makeAcceptanceRuntime(
            workspaceCreator: creator,
            includeDefaultToolWorkspace: false
        )

        let workspaceId = UUID()
        let reference = WorkspaceReference(
            id: workspaceId,
            uri: WorkspaceURI(host: "pk-runtime", path: workspaceRoot.root.path),
            location: .runtimeTimeline,
            rootPath: workspaceRoot.root.path
        )
        let workspaceTool = WorkspaceToolDefinition(
            id: "workspace_echo",
            name: "workspace_echo",
            description: "Echoes a fixed workspace-owned result"
        )
        try await mockPersistence.saveWorkspace(reference)
        try await mockPersistence.addToolToWorkspace(workspaceId: workspaceId, tool: .custom(workspaceTool))
        try await timelineManager.attachWorkspace(workspaceId, to: timelineId)

        mockLLM.mockClient.nextToolCalls = [[MockToolCall(id: "call_ws", name: "workspace_echo")]]
        mockLLM.mockClient.nextResponses = ["", "Workspace tool completed"]

        let events = try await chat.run(
            timelineId: timelineId,
            message: "Use the attached workspace tool"
        ).collect()

        #expect(events.contains(where: {
            if case let .completion(event: .toolExecution(id, status)) = $0,
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
        let (chat, mockLLM, _, timelineId, _, _) = try await makeAcceptanceRuntime()
        let tool = AcceptanceRuntimeTool()

        mockLLM.mockClient.nextToolCalls = [[
            MockToolCall(id: "call_tool", name: "acceptance_tool", arguments: #"{"value":"Berlin"}"#),
        ]]
        mockLLM.mockClient.nextResponses = ["", "Custom tool completed"]

        let events = try await chat.run(
            timelineId: timelineId,
            message: "Run the custom tool",
            tools: [tool.toAnyTool()]
        ).collect()

        #expect(events.contains(where: {
            if case let .completion(event: .toolExecution(id, status)) = $0,
               case let .success(result) = status
            {
                return id == "call_tool" && result.output == "tool:Berlin"
            }
            return false
        }))
    }

    private func makeAcceptanceRuntime(
        workspaceCreator: any WorkspaceCreating = MockWorkspaceCreator(),
        sectionProviders: [any PromptSectionProviding] = [],
        includeDefaultToolWorkspace: Bool = true
    ) async throws -> (PositronicKitCore, MockLLMService, MockPersistenceService, UUID, TestWorkspace, TimelineManager) {
        let mockLLM = MockLLMService()
        let mockPersistence = MockPersistenceService()
        let workspace = TestWorkspace()
        let timelineManager = TimelineManager(
            stores: .init(
                timelineStore: mockPersistence,
                messageStore: mockPersistence,
                workspaceStore: mockPersistence,
                toolPersistence: mockPersistence
            ),
            workspaceRoot: workspace.root,
            workspaceCreator: workspaceCreator,
            sectionProviders: sectionProviders
        )

        let timeline = try await timelineManager.createTimeline(title: "Extension Acceptance")

        if includeDefaultToolWorkspace {
            let workspaceId = UUID()
            let workspaceRef = WorkspaceReference(
                id: workspaceId,
                uri: WorkspaceURI(parsing: "pk://local")!,
                location: .runtimeTimeline,
                originId: nil,
                rootPath: workspace.root.path
            )
            try await mockPersistence.saveWorkspace(workspaceRef)
            try await mockPersistence.addToolToWorkspace(workspaceId: workspaceId, tool: .known("acceptance_tool"))
            try await timelineManager.attachWorkspace(workspaceId, to: timeline.id)
        }

        let chat = PositronicKitCore(
            llmService: mockLLM,
            persistence: .init(
                messageStore: mockPersistence,
                timelinePersistence: mockPersistence,
                workspacePersistence: mockPersistence,
                memoryStore: mockPersistence,
                toolPersistence: mockPersistence,
                agentInstanceStore: mockPersistence,
                requestOriginStore: mockPersistence
            ),
            runtime: .init(
                timelineManager: timelineManager,
                toolRouter: ToolRouter(timelineManager: timelineManager, messageStore: mockPersistence)
            )
        )

        return (chat, mockLLM, mockPersistence, timeline.id, workspace, timelineManager)
    }
}

private struct AcceptancePromptSectionProvider: PromptSectionProviding {
    func sections(for context: PositronicKit.PromptBuildContext) async -> [any Prompt] {
        [TextPrompt("EXTENSION_MARKER: provider injected context for \(context.message)", id: "extension-marker")]
    }
}

private actor AcceptanceChatTurnPlugin: ChatTurnPlugin {
    private var recordedResponses: [String] = []

    func afterTurn(_ turn: CompletedTurn) async throws -> [LLMMessage] {
        recordedResponses.append(turn.fullResponse)
        if recordedResponses.count == 1 {
            return [LLMMessage(role: .user, content: "Plugin follow-up")]
        }
        return []
    }

    func seenResponses() -> [String] {
        recordedResponses
    }
}

private actor AcceptanceWorkspace: WorkspaceProtocol {
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

private final class AcceptanceWorkspaceCreator: WorkspaceCreating, @unchecked Sendable {
    private let lock = NSLock()
    private var created: [UUID] = []

    func create(from reference: WorkspaceReference) throws -> any WorkspaceProtocol {
        lock.lock()
        created.append(reference.id)
        lock.unlock()
        return AcceptanceWorkspace(reference: reference)
    }

    func createdWorkspaceIDs() -> [UUID] {
        lock.lock()
        defer { lock.unlock() }
        return created
    }
}

private struct AcceptanceRuntimeTool: PKShared.Tool, @unchecked Sendable {
    let id = "acceptance_tool"
    let name = "acceptance_tool"
    let description = "Custom runtime tool for extension-point acceptance testing"
    let requiresPermission = false
    let parametersSchema: [String: AnyCodable] = [:]

    func canExecute() async -> Bool {
        true
    }

    func execute(parameters: [String: Any]) async throws -> ToolResult {
        .success("tool:\((parameters["value"] as? String) ?? "missing")")
    }
}
