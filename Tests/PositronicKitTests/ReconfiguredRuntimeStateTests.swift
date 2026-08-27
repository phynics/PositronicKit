import Foundation
import PKContracts
import PKTestSupport
@testable import PositronicKit
import Testing

@Suite("Reconfigured runtime state")
struct ReconfiguredRuntimeStateTests {
    @Test("a post-reconfiguration joined handle cancels a pre-reconfiguration Turn")
    func postReconfigurationHandleCancelsExistingTurn() async throws {
        let originalModel = MockLLMService()
        originalModel.mockClient.neverFinishingStreamCallIndices = [1]
        let originalKit = PositronicKit(languageModel: originalModel)
        let thread = try await originalKit.threads.create(title: "Reconfigured cancellation")
        let requestID = UUID()
        let context = DirectTurnContext(systemInstructions: "", contributor: .host)

        let original = try await originalKit.openThread(thread.id).startDirectTurn(
            message: "same request",
            context: context,
            requestID: requestID
        )
        while originalModel.mockClient.neverFinishingStreamStartCount < 1 {
            await Task.yield()
        }

        let replacementModel = MockLLMService()
        let reconfiguredKit = originalKit.reconfigured(languageModel: replacementModel)
        let joined = try await reconfiguredKit.openThread(thread.id).startDirectTurn(
            message: "same request",
            context: context,
            requestID: requestID
        )

        #expect(joined.id == original.id)
        await joined.cancel()

        #expect(await original.outcome() == .cancelled(reason: "Turn task cancelled."))
        let events = await joined.events().collect()
        #expect(events.filter(\.isTerminal).count == 1)
    }

    @Test("a pre-reconfiguration joined handle cancels a post-reconfiguration Turn")
    func preReconfigurationHandleCancelsNewTurn() async throws {
        let originalModel = MockLLMService()
        let originalKit = PositronicKit(languageModel: originalModel)
        let thread = try await originalKit.threads.create(title: "Reverse cancellation")
        let requestID = UUID()
        let context = DirectTurnContext(systemInstructions: "", contributor: .host)

        let replacementModel = MockLLMService()
        replacementModel.mockClient.neverFinishingStreamCallIndices = [1]
        let reconfiguredKit = originalKit.reconfigured(languageModel: replacementModel)
        let active = try await reconfiguredKit.openThread(thread.id).startDirectTurn(
            message: "same request",
            context: context,
            requestID: requestID
        )
        while replacementModel.mockClient.neverFinishingStreamStartCount < 1 {
            await Task.yield()
        }

        let joined = try await originalKit.openThread(thread.id).startDirectTurn(
            message: "same request",
            context: context,
            requestID: requestID
        )
        #expect(joined.id == active.id)
        await joined.cancel()

        #expect(await active.outcome() == .cancelled(reason: "Turn task cancelled."))
    }

    @Test("reconfiguration shares the Thread manager and its process-local coordinators")
    func sharesRuntimeCoordinatorIdentity() async {
        let originalKit = PositronicKit(languageModel: MockLLMService())
        let reconfiguredKit = originalKit.reconfigured(languageModel: MockLLMService())
        let originalTaskRegistry = await originalKit.threadManager.taskRegistry
        let reconfiguredTaskRegistry = await reconfiguredKit.threadManager.taskRegistry
        let originalWorkspaceCoordinator = await originalKit.threadManager.workspaceExecutionCoordinator
        let reconfiguredWorkspaceCoordinator = await reconfiguredKit.threadManager.workspaceExecutionCoordinator
        let originalAuthorityCoordinator = await originalKit.threadManager.threadAuthorityCoordinator
        let reconfiguredAuthorityCoordinator = await reconfiguredKit.threadManager.threadAuthorityCoordinator

        #expect(originalKit.threadManager === reconfiguredKit.threadManager)
        #expect(originalTaskRegistry === reconfiguredTaskRegistry)
        #expect(originalWorkspaceCoordinator === reconfiguredWorkspaceCoordinator)
        #expect(originalAuthorityCoordinator === reconfiguredAuthorityCoordinator)
    }
}
