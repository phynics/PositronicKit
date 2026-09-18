import Foundation
import PKContracts
import PKTestSupport
import PKUtilities
@testable import PositronicKit
import Testing

@Suite("Introductory runtime internal stories", .tags(.integration))
struct IntroductoryRuntimeInternalStoriesTests {
    @Test("Runtime example creates a timeline executes a tool and returns a final reply")
    func runtimeToolRoundTripExample() async throws {
        let workspace = TestWorkspace()
        let mockLLM = MockLLMService()
        let persistence = MockPersistenceService()

        struct IntroGreetingTool: PKTool {
            let callName = "intro_greet"
            let name = "Intro Greeting"
            let toolDescription = "Greets a user by name for the introductory runtime example."
            let requiresPermission = false

            let parametersSchema = makeEmptyObjectSchema()

            func canExecute() async -> Bool {
                true
            }

            func execute(parameters: [String: AnyCodable]) async throws -> ToolResult {
                let name = parameters["name"]?.value as? String ?? "friend"
                return .success("Hello, \(name)!")
            }
        }

        mockLLM.mockClient.nextToolCalls = [[
            MockToolCall(id: "call_1", name: "intro_greet", arguments: #"{"name":"Taylor"}"#),
        ]]
        mockLLM.mockClient.nextResponses = ["", "I greeted Taylor successfully."]

        let runtime = PKRuntime(configuration: .init(languageModel: mockLLM, persistence: PKRuntime.PersistenceConfiguration(
                runtimeRepository: persistence,
                workspacePersistence: persistence,
                toolPersistence: persistence,
                agentStore: persistence,
                requestOriginStore: persistence
            ), runtime: .init(
                workspaceProfile: .hostManaged(root: workspace.root),
                workspaceCreator: MockWorkspaceCreator()
            )))
        let timelineManager = runtime.timelineManager

        let timeline = try await timelineManager.createTimeline(title: "Intro Example")
        let tool = AnyTool(IntroGreetingTool())
        let workspaceId = UUID()
        let workspaceRef = WorkspaceReference(
            id: workspaceId,
            uri: WorkspaceURI(host: "pk-runtime", path: workspace.root.path),
            location: .runtime,
            rootPath: workspace.root.path
        )
        try await persistence.saveWorkspace(workspaceRef)
        try await persistence.addToolToWorkspace(workspaceID: workspaceId, tool: tool.identity)
        try await timelineManager.attachWorkspace(workspaceId, to: timeline.id)

        let toolManager = await timelineManager.getToolManager(for: timeline.id)
        await toolManager?.updateAvailableTools([tool])

        let events = try await runtime.turnEngine.run(TurnRequest(
            timelineID: timeline.id,
            message: "Greet Taylor using the available tool.",
            tools: [tool]
        )).collect()

        #expect(events.contains(where: {
            if case let .delta(.toolExecution(id, status)) = $0,
               id == "call_1",
               case .attempting = status
            {
                return true
            }
            return false
        }))

        #expect(events.contains(where: {
            if case let .completion(.toolExecution(id, status)) = $0,
               id == "call_1",
               case .success = status
            {
                return true
            }
            return false
        }))

        #expect(events.contains(where: {
            if case let .delta(.generation(text: text)) = $0 {
                return text.contains("I greeted Taylor successfully.")
            }
            return false
        }))

        let messages = try await persistence.fetchMessages(for: timeline.id)
        #expect(messages.contains(where: { $0.role == "assistant" }))
    }
}
