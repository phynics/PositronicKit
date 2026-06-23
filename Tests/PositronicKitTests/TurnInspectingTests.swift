import Foundation
import OpenAI
import PKTestSupport
import Testing
@testable import PKShared
@testable import PositronicKit

private actor InspectionRecorder: TurnInspecting {
    private(set) var values: [TurnInspection] = []

    func didComposeTurn(_ inspection: TurnInspection) {
        values.append(inspection)
    }
}

@Suite(.serialized) @MainActor
struct TurnInspectingTests {
    private final class ChatEngineTestHarness {
        let timelineId = UUID()
        let llm = MockLLMService()
        let persistence = MockPersistenceService()
        let engine: ChatEngine

        init(inspector: (any TurnInspecting)? = nil) async throws {
            let timelineManager = TimelineManager(
                stores: .init(
                    timelineStore: persistence,
                    messageStore: persistence,
                    workspaceStore: persistence,
                    toolPersistence: persistence
                ),
                workspaceRoot: URL(fileURLWithPath: "/tmp/pk-test"),
                workspaceCreator: MockWorkspaceCreator()
            )
            let toolRouter = ToolRouter(
                timelineManager: timelineManager,
                messageStore: persistence
            )
            engine = ChatEngine(
                dependencies: .init(
                    timelineManager: timelineManager,
                    agentInstanceStore: persistence,
                    requestOriginStore: persistence,
                    messageStore: persistence,
                    llmService: llm,
                    toolRouter: toolRouter,
                    chatTurnPlugins: [],
                    turnInspector: inspector
                )
            )

            let session = Timeline(id: timelineId, title: "Test Session")
            try await persistence.saveTimeline(session)

            let workspaceId = UUID()
            let workspaceRef = WorkspaceReference(
                id: workspaceId,
                uri: WorkspaceURI(parsing: "pk://local")!,
                location: .runtimeTimeline,
                originId: nil,
                rootPath: "/tmp"
            )
            try await persistence.saveWorkspace(workspaceRef)
            try await timelineManager.attachWorkspace(workspaceId, to: timelineId)
            try await persistence.addToolToWorkspace(workspaceId: workspaceId, tool: .known("mock_tool"))

            try await timelineManager.hydrateTimeline(id: timelineId)

            if let toolManager = await timelineManager.getToolManager(for: timelineId) {
                var tools = await toolManager.getAvailableTools()
                tools.append(MockTool().toAnyTool())
                await toolManager.updateAvailableTools(tools)

                if let workspace = try? await timelineManager.workspaceManager.getWorkspace(id: workspaceId) {
                    await toolManager.registerWorkspace(workspace)
                }
            }
        }

        func collect(
            message: String,
            tools: [AnyTool] = []
        ) async throws -> [ChatEvent] {
            let stream = try await engine.execute(
                timelineId: timelineId,
                message: message,
                tools: tools
            )

            var events: [ChatEvent] = []
            for try await event in stream {
                events.append(event)
            }
            return events
        }
    }

    struct MockTool: PKShared.Tool, @unchecked Sendable {
        let id = "mock_tool"
        let name = "mock_tool"
        let description = "A mock tool for testing"
        let requiresPermission = false
        let parametersSchema: [String: AnyCodable] = [:]

        var result: ToolResult = .success("Tool result")
        var shouldWait: Bool = false

        func canExecute() async -> Bool {
            true
        }

        func execute(parameters _: [String: Any]) async throws -> ToolResult {
            if shouldWait { try? await Task.sleep(nanoseconds: 100_000_000) }
            if !result.success, result.error == "client_tools_disallowed_on_private_timeline" {
                throw ToolError.attachedToolsDisallowedOnPrivateTimeline
            }
            return result
        }
    }

    @Test("Publishes the exact rendered artifact before generation")
    func publishesExactArtifact() async throws {
        let recorder = InspectionRecorder()
        let harness = try await ChatEngineTestHarness(inspector: recorder)
        harness.llm.mockClient.nextResponse = "Moonlight"

        _ = try await harness.collect(message: "What is yakamoz?")

        let value = try #require(await recorder.values.first)
        let modelName = await harness.llm.configuration.modelName
        #expect(value.timelineId == harness.timelineId)
        #expect(value.turnIndex == 0)
        #expect(value.model == modelName)
        #expect(value.sentMessages == value.rendered.buildMessages())
        #expect(value.estimatedTokens == value.rendered.estimatedTokens)
        #expect(!value.rendered.sections.isEmpty)
        #expect(!value.journal.overlay.addedSemiStableIDs.isEmpty)
        #expect(value.journal.stablePrefixCount == 0)
        #expect(value.journal.didCompact == false)
    }

    @Test("Publishes each model turn in a tool loop")
    func publishesToolLoopTurns() async throws {
        let recorder = InspectionRecorder()
        let harness = try await ChatEngineTestHarness(inspector: recorder)
        harness.llm.mockClient.nextToolCalls = [[MockToolCall(id: "call-1", name: "mock_tool")]]
        harness.llm.mockClient.nextResponses = ["", "Done"]

        _ = try await harness.collect(
            message: "Use the tool",
            tools: [MockTool().toAnyTool()]
        )

        let values = await recorder.values
        #expect(values.map { $0.turnIndex } == [0, 1])
        #expect(values[1].journal.stablePrefixCount > 0)
    }
}
