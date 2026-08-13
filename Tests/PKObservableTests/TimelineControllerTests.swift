import Foundation
import PKObservable
import PKTestSupport
import Testing

@Suite("Thread controller")
@MainActor
struct ThreadControllerTests {
    @Test("mirrors streamed text and completed messages")
    func mirrorsStreamedTextAndCompletedMessages() async throws {
        let runtime = TestRuntime(workspaceRoot: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString))
        runtime.llm.mockClient.nextChunks = [["Hello, ", "world!"]]
        let kit = runtime.positronicKit
        let thread = try await kit.threadManager.createThread(title: "Controller")
        let driver = kit.openThread(thread.id)
        let controller = ThreadController(driver)

        try await controller.send("Hi")

        #expect(controller.isStreaming == false)
        #expect(controller.streamingText.isEmpty)
        #expect(controller.messages.map(\.content) == ["Hi", "Hello, world!"])
    }

    @Test("a completed send clears its active task")
    func completedSendClearsActiveTask() async throws {
        let runtime = TestRuntime(workspaceRoot: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString))
        runtime.llm.mockClient.nextResponses = ["reply"]
        let kit = runtime.positronicKit
        let thread = try await kit.threadManager.createThread(title: "Controller")
        let driver = kit.openThread(thread.id)
        var controller: ThreadController? = ThreadController(driver)
        weak var releasedController: ThreadController? = nil
        releasedController = controller

        try await controller!.send("Hi")
        controller = nil
        await Task.yield()

        #expect(releasedController == nil)
    }

    @Test("a superseding send cancels the previous stream")
    func supersedingSendCancelsPreviousStream() async throws {
        let runtime = TestRuntime(workspaceRoot: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString))
        runtime.llm.mockClient.neverFinishingStreamCallIndices = [1]
        runtime.llm.mockClient.nextResponses = ["second reply"]
        let kit = runtime.positronicKit
        let thread = try await kit.threadManager.createThread(title: "Controller")
        let driver = kit.openThread(thread.id)
        let controller = ThreadController(driver)

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

    @Test("a superseded send cannot clear replacement streaming state")
    func supersededSendCannotClearReplacementStreamingState() async throws {
        let runtime = TestRuntime(workspaceRoot: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString))
        runtime.llm.mockClient.neverFinishingStreamCallIndices = [1, 2]
        runtime.llm.mockClient.nextResponses = ["replacement reply"]
        let kit = runtime.positronicKit
        let thread = try await kit.threadManager.createThread(title: "Controller")
        let driver = kit.openThread(thread.id)
        let controller = ThreadController(driver)

        let first = Task { try await controller.send("first") }
        while controller.isStreaming == false {
            await Task.yield()
        }
        while runtime.llm.mockClient.streamCallCount < 1 {
            await Task.yield()
        }

        let second = Task { try await controller.send("second") }
        while runtime.llm.mockClient.streamCallCount < 2 {
            await Task.yield()
        }
        for _ in 0..<10 {
            await Task.yield()
        }

        #expect(controller.isStreaming)

        try await controller.send("replacement")
        second.cancel()
        first.cancel()
        _ = await second.result
        _ = await first.result
    }
}
