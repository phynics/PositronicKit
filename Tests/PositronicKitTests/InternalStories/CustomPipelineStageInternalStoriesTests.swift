import Foundation
import PKShared
import PKTestSupport
import PKUtilities
@testable import PositronicKit
import Testing

@Suite("Custom pipeline stage internal stories")
struct CustomPipelineStageInternalStoriesTests {
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
            .addingStage(customStage)

        let stream = try await chat.run(ChatRunRequest(
            timelineID: timelineId,
            message: message
        ))

        for try await _ in stream {
            // Drain the stream; any thrown errors will propagate
        }

        let didRun = await tracker.didRun
        #expect(didRun, "Custom stage should have been executed")
    }

    private func makeChat(
        llmService languageModel: any LanguageModel,
        persistence: MockPersistenceService
    ) -> PositronicKit {
        PositronicKit(configuration: .init(
            provider: .init(languageModel: languageModel),
            persistence: .init(
                messageStore: persistence,
                timelinePersistence: persistence,
                workspacePersistence: persistence,
                memoryStore: persistence,
                toolPersistence: persistence,
                agentInstanceStore: persistence,
                requestOriginStore: persistence
            )
        ))
    }
}

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
