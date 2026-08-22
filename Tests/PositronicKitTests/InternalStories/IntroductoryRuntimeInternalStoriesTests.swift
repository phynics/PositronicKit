import Foundation
import PKContracts
import PKTestSupport
import PKUtilities
@testable import PositronicKit
import Testing

@Suite("Introductory runtime internal stories")
struct IntroductoryRuntimeInternalStoriesTests {
    @Test("Runtime example creates a thread executes a tool and returns a final reply")
    func runtimeToolRoundTripExample() async throws {
        let workspace = TestWorkspace()
        let mockLLM = MockLLMService()
        let persistence = MockPersistenceService()

        struct IntroGreetingTool: Tool {
            let callName = "intro_greet"
            let name = "Intro Greeting"
            let description = "Greets a user by name for the introductory runtime example."
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

        let runtime = PositronicKit(configuration: .init(provider: .init(languageModel: mockLLM), persistence: PositronicKit.PersistenceConfiguration(
                messageStore: persistence,
                threadPersistence: persistence,
                workspacePersistence: persistence,
                toolPersistence: persistence,
                agentStore: persistence,
                requestOriginStore: persistence
            ), runtime: .init(
                workspaceCreator: MockWorkspaceCreator(),
                workspaceRoot: workspace.root
            )))
        let threadManager = runtime.threadManager

        let thread = try await threadManager.createThread(title: "Intro Example")
        let tool = IntroGreetingTool().toAnyTool()
        let workspaceId = UUID()
        let workspaceRef = WorkspaceReference(
            id: workspaceId,
            uri: WorkspaceURI(host: "pk-runtime", path: workspace.root.path),
            location: .runtime,
            rootPath: workspace.root.path
        )
        try await persistence.saveWorkspace(workspaceRef)
        try await persistence.addToolToWorkspace(workspaceId: workspaceId, tool: tool.toolReference)
        try await threadManager.attachWorkspace(workspaceId, to: thread.id)

        let toolManager = await threadManager.getToolManager(for: thread.id)
        await toolManager?.updateAvailableTools([tool])

        let events = try await runtime.run(TurnRequest(
            threadID: thread.id,
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

        let messages = try await persistence.fetchMessages(for: thread.id)
        #expect(messages.contains(where: { $0.role == "assistant" }))
    }
}
