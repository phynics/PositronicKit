import Foundation
import PKObservable
import PKTestSupport
import Testing

@Suite("Thread controller")
@MainActor
struct ThreadControllerCompatibilityTests {
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
}
