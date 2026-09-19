import Foundation
import PKContracts
import PKTestSupport
@testable import PositronicKit
import Testing

@Suite("Replacing language model state", .tags(.integration))
struct ReplacingLanguageModelStateTests {
    @Test("a post-replacement joined handle cancels a pre-replacement Turn")
    func postReplacementHandleCancelsExistingTurn() async throws {
        let originalModel = MockLLMService()
        originalModel.mockClient.neverFinishingStreamCallIndices = [1]
        let originalKit = PKRuntime(languageModel: originalModel)
        let timeline = try await originalKit.timelines.create(title: "Replacement cancellation")
        let requestID = UUID()
        let context = DirectTurnContext(systemInstructions: "", contributor: .host)

        let original = try await originalKit.timelines.open(timeline.id).startDirectTurn(
            "same request",
            context: context,
            options: TurnOptions(requestID: requestID)
        )
        while originalModel.mockClient.neverFinishingStreamStartCount < 1 {
            await Task.yield()
        }

        let replacementModel = MockLLMService()
        let replacementKit = originalKit.replacingLanguageModel(replacementModel)
        let joined = try await replacementKit.timelines.open(timeline.id).startDirectTurn(
            "same request",
            context: context,
            options: TurnOptions(requestID: requestID)
        )

        #expect(joined.id == original.id)
        await joined.cancel()

        #expect(try await original.outcome() == .cancelled(reason: "Turn task cancelled."))
        let events = await joined.events().collect()
        #expect(events.filter(\.isTerminal).count == 1)
    }

    @Test("a pre-replacement joined handle cancels a post-replacement Turn")
    func preReplacementHandleCancelsNewTurn() async throws {
        let originalModel = MockLLMService()
        let originalKit = PKRuntime(languageModel: originalModel)
        let timeline = try await originalKit.timelines.create(title: "Reverse cancellation")
        let requestID = UUID()
        let context = DirectTurnContext(systemInstructions: "", contributor: .host)

        let replacementModel = MockLLMService()
        replacementModel.mockClient.neverFinishingStreamCallIndices = [1]
        let replacementKit = originalKit.replacingLanguageModel(replacementModel)
        let active = try await replacementKit.timelines.open(timeline.id).startDirectTurn(
            "same request",
            context: context,
            options: TurnOptions(requestID: requestID)
        )
        while replacementModel.mockClient.neverFinishingStreamStartCount < 1 {
            await Task.yield()
        }

        let joined = try await originalKit.timelines.open(timeline.id).startDirectTurn(
            "same request",
            context: context,
            options: TurnOptions(requestID: requestID)
        )
        #expect(joined.id == active.id)
        await joined.cancel()

        #expect(try await active.outcome() == .cancelled(reason: "Turn task cancelled."))
    }

    @Test("replacement shares the Timeline manager and its process-local coordinators")
    func sharesRuntimeCoordinatorIdentity() async {
        let originalKit = PKRuntime(languageModel: MockLLMService())
        let replacementKit = originalKit.replacingLanguageModel(MockLLMService())
        let originalTaskRegistry = await originalKit.timelineManager.taskRegistry
        let replacementTaskRegistry = await replacementKit.timelineManager.taskRegistry
        let originalWorkspaceCoordinator = await originalKit.timelineManager.workspaceExecutionCoordinator
        let replacementWorkspaceCoordinator = await replacementKit.timelineManager.workspaceExecutionCoordinator
        let originalAuthorityCoordinator = await originalKit.timelineManager.timelineAuthorityCoordinator
        let replacementAuthorityCoordinator = await replacementKit.timelineManager.timelineAuthorityCoordinator

        #expect(originalKit.timelineManager === replacementKit.timelineManager)
        #expect(originalTaskRegistry === replacementTaskRegistry)
        #expect(originalWorkspaceCoordinator === replacementWorkspaceCoordinator)
        #expect(originalAuthorityCoordinator === replacementAuthorityCoordinator)
    }

    @Test("provider selection stays view-local and is pinned when a Timeline handle opens")
    func providerSelectionIsViewLocal() async throws {
        let originalModel = MockLLMService()
        originalModel.mockClient.nextResponse = "original reply"
        let originalKit = PKRuntime(languageModel: originalModel)
        let timeline = try await originalKit.timelines.create(title: "Provider isolation")
        // Opened before the replacement to prove the handle keeps the provider it opened with.
        let originalHandle = originalKit.timelines.open(timeline.id)

        let replacementModel = MockLLMService()
        replacementModel.mockClient.nextResponse = "replacement reply"
        let replacementKit = originalKit.replacingLanguageModel(replacementModel)

        let originalTurn = try await originalHandle.startDirectTurn(
            "first",
            context: DirectTurnContext(systemInstructions: "", contributor: .host)
        )
        _ = await originalTurn.events().collect()
        #expect(try await originalTurn.outcome() == .completed)
        #expect(originalModel.generationCaptureHistory.count == 1)
        #expect(replacementModel.generationCaptureHistory.isEmpty)

        let replacementTurn = try await replacementKit.timelines.open(timeline.id).startDirectTurn(
            "second",
            context: DirectTurnContext(systemInstructions: "", contributor: .host)
        )
        _ = await replacementTurn.events().collect()
        #expect(try await replacementTurn.outcome() == .completed)
        #expect(originalModel.generationCaptureHistory.count == 1)
        #expect(replacementModel.generationCaptureHistory.count == 1)
    }
}
