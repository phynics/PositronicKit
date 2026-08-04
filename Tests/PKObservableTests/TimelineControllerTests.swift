import Foundation
import PKObservable
import PKTestSupport
import Testing

@Suite("Timeline controller")
@MainActor
struct TimelineControllerTests {
    @Test("mirrors streamed text and completed messages")
    func mirrorsStreamedTextAndCompletedMessages() async throws {
        let runtime = TestRuntime(workspaceRoot: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString))
        runtime.llm.mockClient.nextChunks = [["Hello, ", "world!"]]
        let kit = runtime.positronicKit
        let timeline = try await kit.timelineManager.createTimeline(title: "Controller")
        let driver = kit.openTimeline(timeline.id)
        let controller = TimelineController(driver)

        try await controller.send("Hi")

        #expect(controller.isStreaming == false)
        #expect(controller.streamingText.isEmpty)
        #expect(controller.messages.map(\.content) == ["Hi", "Hello, world!"])
    }

    @Test("a superseding send cancels the previous stream")
    func supersedingSendCancelsPreviousStream() async throws {
        let runtime = TestRuntime(workspaceRoot: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString))
        runtime.llm.mockClient.neverFinishingStreamCallIndices = [1]
        runtime.llm.mockClient.nextResponses = ["second reply"]
        let kit = runtime.positronicKit
        let timeline = try await kit.timelineManager.createTimeline(title: "Controller")
        let driver = kit.openTimeline(timeline.id)
        let controller = TimelineController(driver)

        let first = Task { try await controller.send("first") }
        // `isStreaming` flips inside `consume` *before* `driver.send` reaches the LLM,
        // so it is not enough to guarantee "first" has claimed a `chatStream` call. Without the
        // second gate, a superseding "second" can be cancelled-in and reach `chatStream` first,
        // taking call index 1 — the never-finishing stream keyed to that index — and hanging on
        // the idle watchdog. Wait until "first" has actually invoked `chatStream` so the
        // never-finishing index deterministically lands on "first".
        while controller.isStreaming == false {
            await Task.yield()
        }
        while runtime.llm.mockClient.streamCallCount < 1 {
            await Task.yield()
        }

        try await controller.send("second")
        first.cancel()
        _ = await first.result

        #expect(controller.isStreaming == false)
        #expect(controller.messages.map(\.content).contains("second reply"))
    }
}
