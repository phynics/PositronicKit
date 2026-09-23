import Foundation
import JSONSchemaBuilder
import PKContracts
import PKTestSupport
@testable import PositronicKit
import Testing

/// Issue #143: common Turn result and generated-text helpers.
///
/// `TurnHandle.generatedText()` streams assistant text without nested event
/// switching; `TurnHandle.result()` returns one consolidated, durable
/// `TurnResult` (outcome + final assistant message) read from the Timeline
/// runtime repository. The full `events()` stream remains available.
// `.serialized`: generated-text streaming assertions use wall-clock stream waits with a
// two-minute suite time limit. Serialization avoids timing interference between the
// helper scenarios (issue #155).
@Suite("Turn result and generated-text helpers (#143)", .serialized, .timeLimit(.minutes(2)), .tags(.integration))
struct TurnResultTests {
    private func makeKit(_ llm: MockLLMService) -> PKRuntime {
        PKRuntime(languageModel: llm)
    }

    private func makeManagedTurn(
        _ kit: PKRuntime,
        message: String = "hello",
        options: TurnOptions = .init()
    ) async throws -> (TimelineHandle, TurnHandle) {
        let timeline = try await kit.timelines.create(title: "TurnResult")
        let agent = try await kit.agents.create(name: "TurnResult Agent", description: "test")
        try await kit.agents.attach(agent.id, to: timeline.id)
        let driver = kit.timelines.open(timeline.id)
        let turn = try await driver.startTurn(message, options: options)
        return (driver, turn)
    }

    @Test("success streams generated text and returns a completed result with the message")
    func successStreamsTextAndReturnsCompletedResult() async throws {
        let llm = MockLLMService()
        llm.mockClient.nextChunks = [["Hello, ", "world!"]]
        let kit = makeKit(llm)
        let (_, turn) = try await makeManagedTurn(kit)

        var streamed = ""
        for await text in turn.generatedText() {
            streamed += text
        }
        #expect(streamed == "Hello, world!")

        let result = try await turn.result()
        #expect(result.turnID == turn.id)
        #expect(result.timelineID == turn.timelineID)
        #expect(result.outcome == .completed)
        #expect(result.message?.content == "Hello, world!")
    }

    @Test("empty output has a defined completed result with empty content")
    func emptyOutputHasDefinedResult() async throws {
        let llm = MockLLMService()
        llm.mockClient.nextResponse = ""
        let kit = makeKit(llm)
        let (_, turn) = try await makeManagedTurn(kit)

        var streamed = ""
        for await text in turn.generatedText() {
            streamed += text
        }
        #expect(streamed.isEmpty)

        let result = try await turn.result()
        #expect(result.outcome == .completed)
        // The empty assistant row is durable, so the result reports it as-is
        // instead of synthesizing nil: callers distinguish cases via outcome.
        #expect(result.message?.content == "")
    }

    @Test("deferred external tool has a defined interrupted result with no message")
    func deferredToolHasDefinedResult() async throws {
        let workspace = TestWorkspace()
        let persistence = MockPersistenceService()
        let llm = MockLLMService()
        let repository = InMemoryTimelineRuntimeRepository()
        let kit = PKRuntime(configuration: .init(
            languageModel: llm,
            persistence: .init(
                runtimeRepository: repository,
                workspacePersistence: persistence,
                agentStore: persistence,
                requestOriginStore: persistence,
                workspaceBindingRepository: InMemoryWorkspaceBindingRepository()
            ),
            runtime: .init(
                workspaceProfile: .hostManaged(root: workspace.root),
                workspaceCreator: MockWorkspaceCreator()
            )
        ))
        let timeline = try await kit.timelines.create(title: "Deferred Result")
        let attachedWorkspace = WorkspaceReference(
            uri: WorkspaceURI(host: "remote", path: "/deferred"),
            location: .attached,
            tools: [.known("cat")],
            rootPath: workspace.root.path
        )
        try await persistence.saveWorkspace(attachedWorkspace)
        try await persistence.addToolToWorkspace(workspaceID: attachedWorkspace.id, tool: .known("cat"))
        try await kit.timelines.attachWorkspace(attachedWorkspace.id, to: timeline.id)

        llm.mockClient.nextToolCalls = [[MockToolCall(
            id: "deferred-call",
            name: "call_tool",
            arguments: "{\"tool\":\"cat\",\"at\":\"\(attachedWorkspace.id.uuidString)\",\"arguments\":{\"path\":\"README.md\"}}"
        )]]
        llm.mockClient.nextResponse = ""

        let turn = try await timeline.startDirectTurn(
            "Use the attached workspace",
            context: DirectTurnContext(systemInstructions: "", contributor: .host)
        )
        // Drain the stream so the terminal outcome is durable before joining.
        for await _ in turn.events() {}

        let result = try await turn.result()
        #expect(result.outcome == .interrupted(reason: "External tool execution deferred."))
        #expect(result.message == nil)
    }

    @Test("sidecars do not terminate generated text and the result stays completed")
    func sidecarsDoNotTerminateResult() async throws {
        let llm = MockLLMService()
        llm.mockClient.nextChunks = [[
            #"{"response": "Hi there", "sidecar_payload": {"title": "Greeting"}}"#,
        ]]
        let kit = makeKit(llm)
        let directives: [SidecarDirective] = [
            .init(
                name: "title",
                instruction: "Short title.",
                schema: JSONString().definition(),
                streaming: .buffered
            ),
        ]
        let (_, turn) = try await makeManagedTurn(kit, options: TurnOptions(sidecars: directives))

        var streamed = ""
        for await text in turn.generatedText() {
            streamed += text
        }
        #expect(streamed == "Hi there")

        let result = try await turn.result()
        #expect(result.outcome == .completed)
        #expect(result.message?.content == "Hi there")
    }

    @Test("cancellation produces a cancelled result")
    func cancellationProducesCancelledResult() async throws {
        let llm = MockLLMService()
        llm.mockClient.nextChunks = [Array(repeating: "x", count: 50)]
        llm.mockClient.nextStreamWait = 0.05
        let kit = makeKit(llm)
        let (driver, turn) = try await makeManagedTurn(kit)

        let consumeTask = Task {
            for await _ in turn.events() {}
        }
        // Let the stream start, then cancel the Turn.
        try await Task.sleep(for: .milliseconds(150))
        await driver.cancel()
        await consumeTask.value

        let result = try await turn.result()
        #expect(result.outcome == .cancelled(reason: "Turn task cancelled."))
    }

    @Test("failure produces a failed result")
    func failureProducesFailedResult() async throws {
        let llm = MockLLMService()
        llm.mockClient.shouldThrowError = true
        let kit = makeKit(llm)
        let (_, turn) = try await makeManagedTurn(kit)

        for await _ in turn.events() {}

        let result = try await turn.result()
        guard case .failed = result.outcome else {
            Issue.record("Expected a failed outcome, got \(result.outcome)")
            return
        }
    }

    @Test("multiple joiners observe the same durable result")
    func multipleJoinersObserveSameResult() async throws {
        let llm = MockLLMService()
        llm.mockClient.nextResponse = "shared reply"
        let kit = makeKit(llm)
        let (_, turn) = try await makeManagedTurn(kit)

        for await _ in turn.events() {}

        async let first = turn.result()
        async let second = turn.result()
        let (r1, r2) = try await (first, second)
        #expect(r1 == r2)
        #expect(r1.outcome == .completed)
        #expect(r1.message?.content == "shared reply")
    }

    @Test("generated text yields each generation delta exactly once and in order")
    func generatedTextMatchesDeltasExactlyOnce() async throws {
        let llm = MockLLMService()
        llm.mockClient.nextChunks = [["a", "b", "c"]]
        let kit = makeKit(llm)
        let (_, turn) = try await makeManagedTurn(kit)

        // events() and generatedText() share one underlying stream, so the
        // Turn has a single stream consumer: generatedText() here.
        var streamed: [String] = []
        for await text in turn.generatedText() {
            streamed.append(text)
        }

        #expect(streamed == ["a", "b", "c"])
        #expect(streamed.joined() == "abc")

        // The durable result is still joinable after the stream is consumed.
        let result = try await turn.result()
        #expect(result.outcome == .completed)
        #expect(result.message?.content == "abc")
    }
}
