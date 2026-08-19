import Foundation
import OpenAI
@testable import PKShared
import PKTestSupport
import PKUtilities
@testable import PositronicKit
import Testing

private actor InspectionRecorder: PromptObserving {
    private(set) var values: [PromptInspection] = []

    func didComposePrompt(_ inspection: PromptInspection) {
        values.append(inspection)
    }
}

@Suite(.serialized) @MainActor
struct PromptObservingTests {
    private final class FacadeReconfigurationHarness {
        let persistence = MockPersistenceService()
        let inspector = InspectionRecorder()
        let firstLLM = MockLLMService()
        let secondLLM = MockLLMService()

        private(set) var baseKit: PositronicKit!
        private(set) var threadID: UUID!

        init() async throws {
            baseKit = PositronicKit(configuration: .init(
                provider: .init(languageModel: firstLLM),
                persistence: .init(
                    messageStore: persistence,
                    threadPersistence: persistence,
                    workspacePersistence: persistence,
                    memoryStore: persistence,
                    toolPersistence: persistence,
                    agentInstanceStore: persistence,
                    requestOriginStore: persistence
                ),
                runtime: .init(promptObserver: inspector)
            ))
            let thread = try await baseKit.threadManager.createThread(title: "Reconfiguration")
            threadID = thread.id
        }

        func run(
            kit: PositronicKit,
            message: String
        ) async throws {
            let stream = try await kit.run(ChatRunRequest(
                threadID: threadID,
                message: message
            ))
            for try await _ in stream {}
        }
    }

    private final class ChatEngineTestHarness {
        let threadID = UUID()
        let llm = MockLLMService()
        let persistence = MockPersistenceService()
        let engine: ChatEngine

        init(inspector: (any PromptObserving)? = nil) async throws {
            let threadManager = ThreadManager(
                stores: .init(
                    threadStore: persistence,
                    messageStore: persistence,
                    workspaceStore: persistence,
                    toolPersistence: persistence
                ),
                workspaceRoot: URL(fileURLWithPath: "/tmp/pk-test"),
                workspaceCreator: MockWorkspaceCreator()
            )
            let toolRouter = ToolRouter(
                threadManager: threadManager,
                messageStore: persistence
            )
            engine = ChatEngine(
                dependencies: .init(
                    threadManager: threadManager,
                    agentInstanceStore: persistence,
                    requestOriginStore: persistence,
                    messageStore: persistence,
                    llmService: llm,
                    toolRouter: toolRouter,
                    chatTurnPlugins: [],
                    promptObserver: inspector
                )
            )

            let session = Thread(id: threadID, title: "Test Session")
            try await persistence.saveThread(session)

            let workspaceId = UUID()
            let workspaceRef = WorkspaceReference(
                id: workspaceId,
                uri: WorkspaceURI(parsing: "pk://local")!,
                location: .runtimeThread,
                originID: nil,
                rootPath: "/tmp"
            )
            try await persistence.saveWorkspace(workspaceRef)
            try await threadManager.attachWorkspace(workspaceId, to: threadID)
            try await persistence.addToolToWorkspace(workspaceId: workspaceId, tool: .known("mock_tool"))

            try await threadManager.hydrateThread(id: threadID)

            if let toolManager = await threadManager.getToolManager(for: threadID) {
                var tools = await toolManager.getAvailableTools()
                tools.append(MockTool().toAnyTool())
                await toolManager.updateAvailableTools(tools)

                if let workspace = try? await threadManager.workspaceResolver.workspace(id: workspaceId) {
                    await toolManager.registerWorkspace(workspace)
                }
            }
        }

        func collect(
            message: String,
            tools: [AnyTool] = [],
            maxTurns: Int = ChatEngine.Constants.defaultMaxTurns
        ) async throws -> [ChatEvent] {
            let stream = try await engine.execute(
                threadID: threadID,
                message: message,
                tools: tools,
                maxTurns: maxTurns
            )

            var events: [ChatEvent] = []
            for try await event in stream {
                events.append(event)
            }
            return events
        }
    }

    struct MockTool: PKShared.Tool, @unchecked Sendable { // swiftlint:disable:this concurrency_unchecked_sendable -- reviewed test double (see docs/Concurrency/exception-manifest.md)
        let callName = "mock_tool"
        let name = "mock_tool"
        let description = "A mock tool for testing"
        let requiresPermission = false
        let parametersSchema = makeEmptyObjectSchema()

        var result: ToolResult = .success("Tool result")
        var shouldWait: Bool = false

        func canExecute() async -> Bool {
            true
        }

        func execute(parameters _: [String: AnyCodable]) async throws -> ToolResult {
            if shouldWait { try? await Task.sleep(nanoseconds: 100_000_000) }
            if !result.success, result.error == "client_tools_disallowed_on_private_timeline" {
                throw ToolError.attachedToolsDisallowedOnPrivateThread
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
        let modelName = await harness.llm.configuration.activeProviderConfiguration.modelName
        #expect(value.threadID == harness.threadID)
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
        #expect(values.map(\.identity.roundTrip) == [0, 1])
        #expect(values.map(\.identity.sendID).allSatisfy { $0 == values[0].identity.sendID })
        #expect(values[1].journal.stablePrefixCount > 0)
    }

    @Test("Turn identity keeps send identity stable across round trips")
    func turnIdentityStaysStableAcrossRoundTrips() async throws {
        let recorder = InspectionRecorder()
        let harness = try await ChatEngineTestHarness(inspector: recorder)
        harness.llm.mockClient.nextToolCalls = [[MockToolCall(id: "call-1", name: "mock_tool")]]
        harness.llm.mockClient.nextResponses = ["", "Done"]

        _ = try await harness.collect(
            message: "Use the tool",
            tools: [MockTool().toAnyTool()]
        )

        let values = await recorder.values
        let sendIds = values.map(\.identity.sendID)
        #expect(Set(sendIds).count == 1)
        #expect(values.map(\.identity.roundTrip) == [0, 1])
        #expect(values.last?.identity.roundTrip == 1)
    }

    /// PKR-10: `synthesizeFollowUpPrompt` used to rebuild `RenderedPrompt.string` by re-joining
    /// *every* prior section from scratch each `.continueWith` turn (O(n^2) over a long tool-call
    /// loop). It now appends the newly-synthesized section's text onto the already-rendered
    /// accumulated string instead. This test drives several tool-call turns and asserts, at every
    /// turn, that the incrementally-built `rendered.string` is byte-identical to what a full
    /// from-scratch re-join of `sections`/`sectionsByID` would have produced — proving the
    /// optimization preserves output exactly across a multi-turn loop.
    @Test("Rendered prompt string stays correct across many tool-call turns")
    func renderedPromptStringMatchesFullRejoinAcrossManyToolCallTurns() async throws {
        let recorder = InspectionRecorder()
        let harness = try await ChatEngineTestHarness(inspector: recorder)

        let turnCount = 6
        harness.llm.mockClient.nextToolCalls = (0 ..< (turnCount - 1)).map { index in
            [MockToolCall(id: "call-\(index)", name: "mock_tool")]
        }
        harness.llm.mockClient.nextResponses = Array(repeating: "", count: turnCount - 1) + ["Done"]

        _ = try await harness.collect(
            message: "Use the tool repeatedly",
            tools: [MockTool().toAnyTool()],
            maxTurns: turnCount
        )

        let values = await recorder.values
        #expect(values.map(\.turnIndex) == Array(0 ..< turnCount))

        for inspection in values {
            let rendered = inspection.rendered
            let expectedString = rendered.sections
                .compactMap { rendered.sectionsByID[$0.id] }
                .joined(separator: "\n\n---\n\n")
            #expect(rendered.string == expectedString, "turn \(inspection.turnIndex) diverged from a full section re-join")
        }

        // The follow-up sections accumulate one per continued turn — confirms this scenario
        // actually exercises the incremental-append path (not just a single-turn no-op).
        let lastSectionIDs = try Set(#require(values.last?.rendered.sections.map(\.id)))
        let followUpSectionCount = lastSectionIDs.filter { $0.hasPrefix("runtime-follow-up-") }.count
        #expect(followUpSectionCount == turnCount - 1)
    }

    @Test("Reconfigured facade preserves inspection continuity across sends")
    func reconfiguredFacadePreservesInspectionContinuityAcrossSends() async throws {
        let harness = try await FacadeReconfigurationHarness()
        harness.firstLLM.mockClient.nextResponse = "First"
        harness.secondLLM.mockClient.nextResponse = "Second"

        try await harness.run(kit: harness.baseKit, message: "First send")
        let reconfigured = harness.baseKit.reconfigured(
            languageModel: harness.secondLLM,
            generationParameters: .init(temperature: 0.1)
        )
        try await harness.run(kit: reconfigured, message: "Second send")

        let values = await harness.inspector.values
        #expect(values.map(\.turnIndex) == [0, 1])
        #expect(values.map(\.identity.roundTrip) == [0, 0])
        #expect(Set(values.map(\.identity.sendID)).count == 2)
    }

    @Test("Fresh facade without shared state resets inspection continuity explicitly")
    func freshFacadeWithoutSharedStateResetsInspectionContinuityExplicitly() async throws {
        let harness = try await FacadeReconfigurationHarness()
        harness.firstLLM.mockClient.nextResponse = "First"
        harness.secondLLM.mockClient.nextResponse = "Second"

        try await harness.run(kit: harness.baseKit, message: "First send")

        let secondKit = PositronicKit(configuration: .init(
            provider: .init(languageModel: harness.secondLLM),
            persistence: .init(
                messageStore: harness.persistence,
                threadPersistence: harness.persistence,
                workspacePersistence: harness.persistence,
                memoryStore: harness.persistence,
                toolPersistence: harness.persistence,
                agentInstanceStore: harness.persistence,
                requestOriginStore: harness.persistence
            ),
            runtime: .init(promptObserver: harness.inspector)
        ))
        try await harness.run(kit: secondKit, message: "Second send")

        let values = await harness.inspector.values
        #expect(values.map(\.turnIndex) == [0, 0])
        #expect(values.map(\.identity.roundTrip) == [0, 0])
        #expect(Set(values.map(\.identity.sendID)).count == 2)
    }
}
