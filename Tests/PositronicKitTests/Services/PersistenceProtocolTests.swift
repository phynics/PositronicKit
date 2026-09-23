import Foundation
@testable import PositronicKit
@testable import PKContracts
import PKUtilities
import Testing

@Suite(.tags(.unit))
struct PersistenceProtocolTests {
    /// This test verifies that we can define a mock that conforms to all new domain protocols
    /// effectively replacing the God protocol with composed requirements.
    @Test("Protocol Composition Test")
    func protocolComposition() {
        let mock = MockPersistenceStore()

        // Verify it conforms to all required domains
        let _: TimelineMessageStoreProtocol = mock
        let _: TimelinePersistenceProtocol = mock
        let _: WorkspaceStore = mock
    }
}

/// Minimal mock to verify protocol definitions exist
final class MockPersistenceStore:
    TimelineMessageStoreProtocol,
    TimelinePersistenceProtocol,
    WorkspaceStore,
    @unchecked Sendable // swiftlint:disable:this concurrency_unchecked_sendable -- reviewed test double (see docs/Concurrency/exception-manifest.md)
{
    // MessageStoreProtocol
    func saveMessage(_: TimelineMessage) async throws {}
    func fetchMessages(for _: UUID) async throws -> [TimelineMessage] {
        []
    }

    func deleteMessages(for _: UUID) async throws {}
    func pruneMessages(olderThan _: TimeInterval, dryRun _: Bool) async throws -> Int {
        0
    }

    func fetchSnapshots(for _: UUID) async throws -> [TurnSnapshot] {
        []
    }

    // TimelinePersistenceProtocol
    func saveTimeline(_: TimelineRecord) async throws {}
    func fetchTimeline(id _: UUID) async throws -> TimelineRecord? {
        nil
    }

    func fetchAllTimelines(includeArchived _: Bool) async throws -> [TimelineRecord] {
        []
    }

    func deleteTimeline(id _: UUID) async throws {}
    func pruneTimelines(olderThan _: TimeInterval, excluding _: [UUID], dryRun _: Bool) async throws -> Int {
        0
    }

    // WorkspaceStore
    func saveWorkspace(_: WorkspaceReference) async throws {}
    func fetchWorkspace(id _: UUID) async throws -> WorkspaceReference? {
        nil
    }

    func fetchWorkspace(id _: UUID, includeTools _: Bool) async throws -> WorkspaceReference? {
        nil
    }

    func fetchAllWorkspaces() async throws -> [WorkspaceReference] {
        []
    }

    func deleteWorkspace(id _: UUID) async throws {}
}
