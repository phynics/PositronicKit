import Foundation
import PKShared
import PKUtilities
import PKTestSupport
@testable import PositronicKit
import Testing

/// PKRR-005: hydration failure during `run(_:)` must propagate as a typed `TimelineError`
/// before any user input is persisted. A brand-new, never-persisted timeline throws
/// `TimelineError.timelineNotFound`; a transient store fault throws `TimelineError.unavailable`.
/// Neither is swallowed — the turn does not proceed unhydrated.
struct HydrationFailurePropagationTests {
    @Test("run(_:) throws timelineNotFound for a never-created timeline ID (PKRR-005)")
    func runThrowsForMissingTimeline() async throws {
        let mockLLM = MockLLMService()
        let kit = PositronicKit(configuration: .init(
            provider: .init(languageModel: mockLLM),
            persistence: .inMemory()
        ))

        let unresolvedTimelineId = UUID()

        await #expect(throws: TimelineError.timelineNotFound) {
            _ = try await kit.run(ChatRunRequest(
                timelineID: unresolvedTimelineId,
                message: "should not reach the engine"
            ))
        }

        #expect(mockLLM.chatCaptureHistory.isEmpty)
    }

    @Test("run(_:) throws unavailable when the timeline store fails (PKRR-005)")
    func runThrowsUnavailableForStoreFailure() async throws {
        let failingTimelinePersistence = FailingTimelinePersistence(fetchFails: true)
        let mockLLM = MockLLMService()
        let kit = PositronicKit(configuration: .init(
            provider: .init(languageModel: mockLLM),
            persistence: .init(timelinePersistence: failingTimelinePersistence)
        ))

        let unresolvedTimelineId = UUID()

        await #expect(throws: TimelineError.unavailable) {
            _ = try await kit.run(ChatRunRequest(
                timelineID: unresolvedTimelineId,
                message: "should not reach the engine"
            ))
        }

        // The hydration attempt must actually have hit the store, proving
        // `resolveTurnBriefingBuilder` didn't short-circuit before reaching it.
        #expect(failingTimelinePersistence.fetchAttemptCount >= 1)
    }

    @Test("run returns a stream before a provider failure surfaces with typed identity")
    func providerFailureSurfacesThroughReturnedStream() async throws {
        let foreignError = NSError(domain: "FacadeRunForeign", code: 91)
        let mockLLM = MockLLMService()
        mockLLM.stubbedStream = AsyncThrowingStream { continuation in
            continuation.finish(throwing: foreignError)
        }
        let kit = PositronicKit(configuration: .init(
            provider: .init(languageModel: mockLLM),
            persistence: .inMemory()
        ))
        let timeline = try await kit.timelineManager.createTimeline()

        let stream = try await kit.run(ChatRunRequest(
            timelineID: timeline.id,
            message: "fail during provider streaming"
        ))

        do {
            _ = try await stream.collect()
            Issue.record("Expected the returned stream to surface the provider failure")
        } catch let error as PipelineError {
            guard case let .stageFailed(_, underlying) = error else {
                Issue.record("Expected PipelineError.stageFailed, got \(error)")
                return
            }
            let streamError = try #require(underlying as? LLMStreamError)
            #expect(streamError.errorDomain == PKErrorDomain.llm)
            #expect(streamError.errorCode == 1005)
            #expect((streamError.underlyingError as NSError) === foreignError)
            let identity = ChatEvent.ErrorIdentity.extracting(from: error)
            #expect(identity?.domain == PKErrorDomain.llm)
            #expect(identity?.code == 1005)
        } catch {
            Issue.record("Expected a typed pipeline provider failure, got \(error)")
        }
    }
}
