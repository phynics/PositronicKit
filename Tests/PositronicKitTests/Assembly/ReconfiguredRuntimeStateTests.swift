import Foundation
import PKContracts
import PKTestSupport
@testable import PositronicKit
import Testing

@Suite("Reconfigured runtime state", .tags(.integration))
struct ReconfiguredRuntimeStateTests {
    @Test("a post-reconfiguration joined handle cancels a pre-reconfiguration Turn")
    func postReconfigurationHandleCancelsExistingTurn() async throws {
        let originalModel = MockLLMService()
        originalModel.mockClient.neverFinishingStreamCallIndices = [1]
        let originalKit = PKRuntime(languageModel: originalModel)
        let timeline = try await originalKit.timelines.create(title: "Reconfigured cancellation")
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
        let reconfiguredKit = originalKit.reconfigured(languageModel: replacementModel)
        let joined = try await reconfiguredKit.timelines.open(timeline.id).startDirectTurn(
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

    @Test("a pre-reconfiguration joined handle cancels a post-reconfiguration Turn")
    func preReconfigurationHandleCancelsNewTurn() async throws {
        let originalModel = MockLLMService()
        let originalKit = PKRuntime(languageModel: originalModel)
        let timeline = try await originalKit.timelines.create(title: "Reverse cancellation")
        let requestID = UUID()
        let context = DirectTurnContext(systemInstructions: "", contributor: .host)

        let replacementModel = MockLLMService()
        replacementModel.mockClient.neverFinishingStreamCallIndices = [1]
        let reconfiguredKit = originalKit.reconfigured(languageModel: replacementModel)
        let active = try await reconfiguredKit.timelines.open(timeline.id).startDirectTurn(
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

    @Test("reconfiguration shares the Timeline manager and its process-local coordinators")
    func sharesRuntimeCoordinatorIdentity() async {
        let originalKit = PKRuntime(languageModel: MockLLMService())
        let reconfiguredKit = originalKit.reconfigured(languageModel: MockLLMService())
        let originalTaskRegistry = await originalKit.timelineManager.taskRegistry
        let reconfiguredTaskRegistry = await reconfiguredKit.timelineManager.taskRegistry
        let originalWorkspaceCoordinator = await originalKit.timelineManager.workspaceExecutionCoordinator
        let reconfiguredWorkspaceCoordinator = await reconfiguredKit.timelineManager.workspaceExecutionCoordinator
        let originalAuthorityCoordinator = await originalKit.timelineManager.timelineAuthorityCoordinator
        let reconfiguredAuthorityCoordinator = await reconfiguredKit.timelineManager.timelineAuthorityCoordinator

        #expect(originalKit.timelineManager === reconfiguredKit.timelineManager)
        #expect(originalTaskRegistry === reconfiguredTaskRegistry)
        #expect(originalWorkspaceCoordinator === reconfiguredWorkspaceCoordinator)
        #expect(originalAuthorityCoordinator === reconfiguredAuthorityCoordinator)
    }
}
