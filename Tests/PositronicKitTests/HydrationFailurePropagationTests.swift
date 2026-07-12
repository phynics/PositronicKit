import Foundation
import PKShared
import PKUtilities
import PKTestSupport
@testable import PositronicKit
import Testing

/// PKFLAKE-005: a hydration failure during `run(_:)` must be logged (not silently
/// swallowed) rather than propagated — a brand-new, never-persisted timeline throws the
/// same `TimelineError.timelineNotFound` as a transient store fault, and that is the
/// expected first-message flow, so the turn proceeds with an unhydrated context.
struct HydrationFailurePropagationTests {
    @Test("run(_:) survives a hydration failure and proceeds unhydrated instead of throwing (PKFLAKE-005)")
    func runSurvivesHydrationFailure() async throws {
        let failingTimelinePersistence = FailingTimelinePersistence(fetchFails: true)
        let mockLLM = MockLLMService()
        let kit = PositronicKit(configuration: .init(
            provider: .init(llmService: mockLLM),
            persistence: .init(timelinePersistence: failingTimelinePersistence)
        ))

        let unresolvedTimelineId = UUID()

        // The timeline is unknown to the facade's cache, so `resolveContextManager`
        // falls through to `hydrateTimeline`, which hits the failing store. The turn
        // must still proceed (not throw) — hydration failure is logged, not propagated.
        let stream = try await kit.run(ChatRunRequest(
            timelineId: unresolvedTimelineId,
            message: "should still reach the engine unhydrated"
        ))
        for try await _ in stream {}

        // The hydration attempt must actually have hit the store, proving
        // `resolveContextManager` didn't short-circuit before reaching it.
        #expect(failingTimelinePersistence.fetchAttemptCount >= 1)
    }
}
