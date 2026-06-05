import Foundation
import PKPrompt
import PKShared
import PKTestSupport
import PositronicKitExamples
import Testing
@testable import PositronicKit

@Suite("Introductory stories")
struct IntroductoryStoriesTests {
    @Test("Prompt journaling example shows base overlay and compaction flow")
    func promptJournalingExample() async {
        var journal = PromptJournal()

        let initial = await (try! PKPromptExamples.makeStableToolingPrompt(
            tools: [
                .init(id: "build", summary: "Builds the package."),
                .init(id: "test", summary: "Runs the test suite."),
            ],
            userQuery: "What should I run first?"
        ).assemblePrompt()).render()

        let updated = await (try! PKPromptExamples.makeStableToolingPrompt(
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
        let timelineManager = TimelineManager(
            stores: .init(
                timelineStore: persistence,
                messageStore: persistence,
                workspaceStore: persistence,
                toolPersistence: persistence
            ),
            workspaceRoot: workspace.root,
            workspaceCreator: MockWorkspaceCreator()
        )

        struct IntroGreetingTool: Tool {
            let id = "intro_greet"
            let name = "Intro Greeting"
            let description = "Greets a user by name for the introductory runtime example."
            let requiresPermission = false

            var parametersSchema: [String: AnyCodable] {
                [
                    "type": .string("object"),
                    "properties": .dictionary([
                        "name": .dictionary([
                            "type": .string("string"),
                        ]),
                    ]),
                    "required": .array([.string("name")]),
                ]
            }

            func canExecute() async -> Bool { true }

            func execute(parameters: [String: Any]) async throws -> ToolResult {
                let name = parameters["name"] as? String ?? "friend"
                return .success("Hello, \(name)!")
            }
        }

        mockLLM.mockClient.nextToolCalls = [[
            MockToolCall(id: "call_1", name: "intro_greet", arguments: #"{"name":"Taylor"}"#),
        ]]
        mockLLM.mockClient.nextResponses = ["", "I greeted Taylor successfully."]

        let runtime = PositronicKitCore(
            llmService: mockLLM,
            persistence: PositronicKitCore.PersistenceConfiguration(
                messageStore: persistence,
                timelinePersistence: persistence,
                workspacePersistence: persistence,
                memoryStore: persistence,
                toolPersistence: persistence,
                agentInstanceStore: persistence,
                requestOriginStore: persistence,
                agentTemplateStore: persistence
            ),
            runtime: .init(
                timelineManager: timelineManager,
                toolRouter: ToolRouter(timelineManager: timelineManager, messageStore: persistence)
            )
        )

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

        let events = try await runtime.run(
            timelineId: timeline.id,
            message: "Greet Taylor using the available tool.",
            tools: [tool]
        ).collect()

        #expect(events.contains(where: {
            if case let .delta(event: .toolExecution(id, status)) = $0,
               id == "call_1",
               case .attempting = status {
                return true
            }
            return false
        }))

        #expect(events.contains(where: {
            if case let .completion(event: .toolExecution(id, status)) = $0,
               id == "call_1",
               case .success = status {
                return true
            }
            return false
        }))

        #expect(events.contains(where: {
            if case let .delta(event: .generation(text: text)) = $0 {
                return text.contains("I greeted Taylor successfully.")
            }
            return false
        }))

        let messages = try await persistence.fetchMessages(for: timeline.id)
        #expect(messages.contains(where: { $0.role == "assistant" }))
    }
}
