import Foundation
import PKPrompt
import PKShared
import PKTestSupport
@testable import PositronicKit
import PositronicKitExamples
import Testing

@Suite("Introductory stories")
struct IntroductoryStoriesTests {
    @Test("Prompt journaling example shows base overlay and compaction flow")
    func promptJournalingExample() async throws {
        var journal = PromptJournal()

        let initial = try await (PKPromptExamples.makeStableToolingPrompt(
            tools: [
                .init(id: "build", summary: "Builds the package."),
                .init(id: "test", summary: "Runs the test suite."),
            ],
            userQuery: "What should I run first?"
        ).assemblePrompt()).render()

        let updated = try await (PKPromptExamples.makeStableToolingPrompt(
            tools: [
                .init(id: "build", summary: "Builds the package."),
                .init(id: "test", summary: "Runs the full test suite."),
                .init(id: "lint", summary: "Checks formatting and style."),
            ],
            userQuery: "What should I run first?"
        ).assemblePrompt()).render()

        let initialPlan = journal.observe(initial)
        #expect(initialPlan.baseSections.map(\.section.id) == ["system", "tool-build", "tool-test"])
        #expect(initialPlan.overlaySections.isEmpty)
        #expect(initialPlan.volatileSections.map(\.section.id) == ["user_query"])

        let updatedPlan = journal.observe(updated)
        #expect(updatedPlan.baseSections.map(\.section.id) == ["system", "tool-build", "tool-test"])
        #expect(updatedPlan.overlaySections.map(\.section.id) == ["tool-test", "tool-lint"])
        #expect(updatedPlan.overlaySections.allSatisfy { $0.layer == .overlay })

        let compacted = journal.compact()
        #expect(compacted?.overlaySections.isEmpty == true)
        #expect(compacted?.baseSections.map(\.section.id) == ["system", "tool-build", "tool-test", "tool-lint"])
    }

    @Test("Runtime example creates a timeline executes a tool and returns a final reply")
    func runtimeToolRoundTripExample() async throws {
        let workspace = TestWorkspace()
        let mockLLM = MockLLMService()
        let persistence = MockPersistenceService()

        struct IntroGreetingTool: Tool {
            let id = "intro_greet"
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

        let runtime = PositronicKit(
            llmService: mockLLM,
            persistence: PositronicKit.PersistenceConfiguration(
                messageStore: persistence,
                timelinePersistence: persistence,
                workspacePersistence: persistence,
                memoryStore: persistence,
                toolPersistence: persistence,
                agentInstanceStore: persistence,
                requestOriginStore: persistence
            ),
            runtime: .init(
                workspaceCreator: MockWorkspaceCreator(),
                workspaceRoot: workspace.root
            )
        )
        let timelineManager = runtime.timelineManager

        let timeline = try await timelineManager.createTimeline(title: "Intro Example")
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
        try await timelineManager.attachWorkspace(workspaceId, to: timeline.id)

        let toolManager = await timelineManager.getToolManager(for: timeline.id)
        await toolManager?.updateAvailableTools([tool])

        let events = try await runtime.run(ChatRunRequest(
            timelineId: timeline.id,
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
