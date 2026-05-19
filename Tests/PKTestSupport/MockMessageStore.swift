import Foundation
import PositronicKit
import PKShared

public final class MockMessageStore: MessageStoreProtocol, @unchecked Sendable {
    private let backing = InMemoryMessageStore()

    public var messages: [ConversationMessage] {
        get { (try? BlockingAsync.run { [self] in await self.backing.allMessages() }) ?? [] }
        set { _ = try? BlockingAsync.run { [self] in await self.backing.replaceMessages(newValue) } }
    }

    public init() {}

    public func saveMessage(_ message: ConversationMessage) async throws {
        try await backing.saveMessage(message)
    }

    public func fetchMessages(for timelineId: UUID) async throws -> [ConversationMessage] {
        try await backing.fetchMessages(for: timelineId)
    }

    public func deleteMessages(for timelineId: UUID) async throws {
        try await backing.deleteMessages(for: timelineId)
    }

    public func pruneMessages(olderThan _: TimeInterval, dryRun _: Bool) async throws -> Int {
        return 0
    }

    public func fetchSnapshots(for timelineId: UUID) async throws -> [TurnSnapshot] {
        try await backing.fetchSnapshots(for: timelineId)
    }
}
