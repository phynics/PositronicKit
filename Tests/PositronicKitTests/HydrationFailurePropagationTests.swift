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
            provider: .init(llmService: mockLLM),
            persistence: .inMemory()
        ))

        let unresolvedTimelineId = UUID()

        await #expect(throws: TimelineError.timelineNotFound) {
            _ = try await kit.run(ChatRunRequest(
                timelineId: unresolvedTimelineId,
                message: "should not reach the engine"
            ))
        }
    }

    @Test("run(_:) throws unavailable when the timeline store fails (PKRR-005)")
    func runThrowsUnavailableForStoreFailure() async throws {
        let failingTimelinePersistence = FailingTimelinePersistence(fetchFails: true)
        let mockLLM = MockLLMService()
        let kit = PositronicKit(configuration: .init(
            provider: .init(llmService: mockLLM),
            persistence: .init(timelinePersistence: failingTimelinePersistence)
        ))

        let unresolvedTimelineId = UUID()

        await #expect(throws: TimelineError.unavailable) {
            _ = try await kit.run(ChatRunRequest(
                timelineId: unresolvedTimelineId,
                message: "should not reach the engine"
            ))
        }

        // The hydration attempt must actually have hit the store, proving
        // `resolveTurnBriefingBuilder` didn't short-circuit before reaching it.
        #expect(failingTimelinePersistence.fetchAttemptCount >= 1)
    }
}
