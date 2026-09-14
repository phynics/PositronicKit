import Foundation
@testable import PKContracts
import PKUtilities
import PKTestSupport
@testable import PositronicKit
import Testing

/// Regression coverage for the `dryRun` contract on `pruneMessages` / `pruneTimelines`:
/// `dryRun: true` must never mutate persisted state (PKAPI-013).
///
/// The in-memory `MessageStoreProtocol` / `TimelinePersistenceProtocol`
/// conformers shipped from this package (the stub `InMemory*` stores and `PKTestSupport`'s
/// `Mock*` stores) currently implement `prune*` as unconditional no-ops that always return `0`.
/// That trivially satisfies "dry run never deletes," but these tests pin the behavior down
/// explicitly so a future real implementation (or a stub that starts actually deleting rows)
/// can't silently violate the dry-run contract.
@Suite("Prune dryRun contract", .tags(.integration))
struct PruneDryRunTests {
    @Test("MockMessageStore: pruneMessages(dryRun: true) does not delete messages")
    func mockMessageStoreDryRunPreservesMessages() async throws {
        let store = MockMessageStore()
        let timelineID = UUID()
        let message = TimelineMessage(
            timelineID: timelineID,
            role: .user,
            content: "hello",
            timestamp: Date(timeIntervalSince1970: 0)
        )
        try await store.saveMessage(message)

        _ = try await store.pruneMessages(olderThan: 0, dryRun: true)

        let remaining = try await store.fetchMessages(for: timelineID)
        #expect(remaining.count == 1)
    }

    @Test("InMemoryMessageStore: pruneMessages(dryRun: true) does not delete messages")
    func inMemoryMessageStoreDryRunPreservesMessages() async throws {
        let store = InMemoryMessageStore()
        let timelineID = UUID()
        let message = TimelineMessage(
            timelineID: timelineID,
            role: .user,
            content: "hello",
            timestamp: Date(timeIntervalSince1970: 0)
        )
        try await store.saveMessage(message)

        _ = try await store.pruneMessages(olderThan: 0, dryRun: true)

        let remaining = try await store.fetchMessages(for: timelineID)
        #expect(remaining.count == 1)
    }

    @Test("MockTimelinePersistence: pruneTimelines(dryRun: true) does not delete timelines")
    func mockTimelinePersistenceDryRunPreservesTimelines() async throws {
        let store = MockTimelinePersistence()
        let timeline = TimelineRecord(createdAt: Date(timeIntervalSince1970: 0))
        try await store.saveTimeline(timeline)

        _ = try await store.pruneTimelines(olderThan: 0, excluding: [], dryRun: true)

        let remaining = try await store.fetchTimeline(id: timeline.id)
        #expect(remaining != nil)
    }

    @Test("InMemoryTimelinePersistence: pruneTimelines(dryRun: true) does not delete timelines")
    func inMemoryTimelinePersistenceDryRunPreservesTimelines() async throws {
        let store = InMemoryTimelinePersistence()
        let timeline = TimelineRecord(createdAt: Date(timeIntervalSince1970: 0))
        try await store.saveTimeline(timeline)

        _ = try await store.pruneTimelines(olderThan: 0, excluding: [], dryRun: true)

        let remaining = try await store.fetchTimeline(id: timeline.id)
        #expect(remaining != nil)
    }

}
