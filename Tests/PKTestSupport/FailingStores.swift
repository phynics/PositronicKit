import Foundation
import PKShared
import PositronicKit
import Synchronization

/// Error thrown by the failing persistence mocks to simulate store failures in
/// failure-path tests.
public enum FailingStoreError: Error, Sendable {
    case saveFailed
    case fetchFailed
    case deleteFailed
}

/// A `MessageStoreProtocol` mock that throws on `saveMessage` while recording each
/// attempted message, so failure-path tests can assert the save was both attempted
/// and non-fatal to the caller (e.g. an audit-log save that the caller must survive).
public final class FailingMessageStore: MessageStoreProtocol, @unchecked Sendable {
    private let attemptedState = Mutex<[ConversationMessage]>([])

    /// Messages handed to `saveMessage` before it threw, in arrival order.
    public var attemptedMessages: [ConversationMessage] {
        attemptedState.withLock { $0 }
    }

    public init() {}

    public func saveMessage(_ message: ConversationMessage) async throws {
        attemptedState.withLock { $0.append(message) }
        throw FailingStoreError.saveFailed
    }

    public func fetchMessages(for timelineId: UUID) async throws -> [ConversationMessage] { [] }

    public func deleteMessages(for timelineId: UUID) async throws {}

    public func pruneMessages(olderThan _: TimeInterval, dryRun _: Bool) async throws -> Int { 0 }

    public func fetchSnapshots(for timelineId: UUID) async throws -> [TurnSnapshot] { [] }
}

/// A `TimelinePersistenceProtocol` mock that can be configured to throw on
/// `fetchTimeline`, `saveTimeline`, and/or `deleteTimeline`, delegating all other
/// operations to an in-memory backing store. Use it to drive failure-path coverage
/// for hydration (`fetchTimeline`) and private-timeline cleanup (`deleteTimeline`).
public final class FailingTimelinePersistence: TimelinePersistenceProtocol, @unchecked Sendable {
    private let backing = MockTimelinePersistence()
    private let fetchFails: Bool
    private let saveFails: Bool
    private let deleteFails: Bool
    private let fetchAttemptState = Mutex<Int>(0)
    private let deleteAttemptState = Mutex<Int>(0)

    public init(
        fetchFails: Bool = false,
        saveFails: Bool = false,
        deleteFails: Bool = false
    ) {
        self.fetchFails = fetchFails
        self.saveFails = saveFails
        self.deleteFails = deleteFails
    }

    /// Number of times `fetchTimeline` was invoked.
    public var fetchAttemptCount: Int { fetchAttemptState.withLock { $0 } }

    /// Number of times `deleteTimeline` was invoked.
    public var deleteAttemptCount: Int { deleteAttemptState.withLock { $0 } }

    public func saveTimeline(_ timeline: Timeline) async throws {
        if saveFails { throw FailingStoreError.saveFailed }
        try await backing.saveTimeline(timeline)
    }

    public func fetchTimeline(id: UUID) async throws -> Timeline? {
        fetchAttemptState.withLock { $0 += 1 }
        if fetchFails { throw FailingStoreError.fetchFailed }
        return try await backing.fetchTimeline(id: id)
    }

    public func fetchAllTimelines(includeArchived: Bool) async throws -> [Timeline] {
        try await backing.fetchAllTimelines(includeArchived: includeArchived)
    }

    public func deleteTimeline(id: UUID) async throws {
        deleteAttemptState.withLock { $0 += 1 }
        if deleteFails { throw FailingStoreError.deleteFailed }
        try await backing.deleteTimeline(id: id)
    }

    public func pruneTimelines(
        olderThan timeInterval: TimeInterval,
        excluding excludedTimelineIds: [UUID],
        dryRun: Bool
    ) async throws -> Int {
        try await backing.pruneTimelines(
            olderThan: timeInterval,
            excluding: excludedTimelineIds,
            dryRun: dryRun
        )
    }
}
