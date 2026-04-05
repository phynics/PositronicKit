import Foundation
@testable import MonadCore
import MonadPrompt
@testable import MonadShared
import MonadTestSupport
import Testing

struct MonadCoreTests {
    @Test
    func basicExecution() async throws {
        let mockLLM = MockLLMService()
        let mockPersistence = MockPersistenceService()

        let timelineId = UUID()
        let message = "Hello, Morty!"

        try await mockPersistence.saveTimeline(Timeline(id: timelineId, title: "Test"))

        let chat = makeChat(llmService: mockLLM, persistence: mockPersistence)

        let stream = try await chat.run(
            timelineId: timelineId,
            message: message
        )

        #expect(stream != nil)
    }

    @Test
    func customPipelineStage() async throws {
        let mockLLM = MockLLMService()
        let mockPersistence = MockPersistenceService()

        let timelineId = UUID()
        let message = "Hello, custom stage!"

        try await mockPersistence.saveTimeline(Timeline(id: timelineId, title: "Test"))

        let tracker = MockStageRunTracker()
        let customStage = MockCustomStage(tracker: tracker)

        let chat = makeChat(llmService: mockLLM, persistence: mockPersistence)
            .addStage(customStage)

        let stream = try await chat.run(
            timelineId: timelineId,
            message: message
        )

        for try await _ in stream {
            // Drain the stream; any thrown errors will propagate
        }

        let didRun = await tracker.didRun
        #expect(didRun, "Custom stage should have been executed")
    }

    // MARK: - Helpers

    private func makeChat(
        llmService: any LLMServiceProtocol,
        persistence: MockPersistenceService
    ) -> MonadCore {
        MonadCore(
            llmService: llmService,
            persistence: .init(
                messageStore: persistence,
                timelinePersistence: persistence,
                workspacePersistence: persistence,
                memoryStore: persistence,
                toolPersistence: persistence,
                agentInstanceStore: persistence,
                clientStore: persistence,
                agentTemplateStore: persistence
            )
        )
    }
}

// MARK: - Test Helpers

private actor MockStageRunTracker {
    var didRun = false
    func setRun() {
        didRun = true
    }
}

private struct MockCustomStage: PipelineStage {
    let tracker: MockStageRunTracker
    var id: String {
        "MockCustomStage"
    }

    func process(_: ChatTurnContext) async throws -> AsyncThrowingStream<ChatEvent, Error> {
        await tracker.setRun()
        return AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }
}
