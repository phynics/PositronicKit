import Foundation
import PKObservable
import PKTestSupport
import Testing

@Suite("Observable conversation")
@MainActor
struct ObservableConversationTests {
    @Test("mirrors streamed text and completed messages")
    func mirrorsStreamedTextAndCompletedMessages() async throws {
        let runtime = TestRuntime(workspaceRoot: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString))
        runtime.llm.mockClient.nextChunks = [["Hello, ", "world!"]]
        let conversation = try await runtime.buildCore().newConversation()
        let observable = ObservableConversation(conversation)

        try await observable.send("Hi")

        #expect(observable.isStreaming == false)
        #expect(observable.streamingText.isEmpty)
        #expect(observable.messages.map(\.content) == ["Hi", "Hello, world!"])
    }

    @Test("a superseding send cancels the previous stream")
    func supersedingSendCancelsPreviousStream() async throws {
        let runtime = TestRuntime(workspaceRoot: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString))
        runtime.llm.mockClient.neverFinishingStreamCallIndices = [1]
        runtime.llm.mockClient.nextResponses = ["second reply"]
        let conversation = try await runtime.buildCore().newConversation()
        let observable = ObservableConversation(conversation)

        let first = Task { try await observable.send("first") }
        // `isStreaming` flips inside `consume` *before* `conversation.send` reaches the LLM,
        // so it is not enough to guarantee "first" has claimed a `chatStream` call. Without the
        // second gate, a superseding "second" can be cancelled-in and reach `chatStream` first,
        // taking call index 1 — the never-finishing stream keyed to that index — and hanging on
        // the idle watchdog. Wait until "first" has actually invoked `chatStream` so the
        // never-finishing index deterministically lands on "first".
        while observable.isStreaming == false {
            await Task.yield()
        }
        while runtime.llm.mockClient.streamCallCount < 1 {
            await Task.yield()
        }

        try await observable.send("second")
        first.cancel()
        _ = await first.result

        #expect(observable.isStreaming == false)
        #expect(observable.messages.map(\.content).contains("second reply"))
    }
}
