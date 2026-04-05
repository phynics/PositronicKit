import Foundation
import MonadCore
import MonadShared

public final class MockMessageStore: MessageStoreProtocol, @unchecked Sendable {
    public var messages: [ConversationMessage] = []

    public init() {}

    public func saveMessage(_ message: ConversationMessage) async throws {
        messages.append(message)
    }

    public func fetchMessages(for timelineId: UUID) async throws -> [ConversationMessage] {
        return messages.filter { $0.timelineId == timelineId }
    }

    public func deleteMessages(for timelineId: UUID) async throws {
        messages.removeAll(where: { $0.timelineId == timelineId })
    }

    public func pruneMessages(olderThan _: TimeInterval, dryRun _: Bool) async throws -> Int {
        return 0
    }

    public func fetchSnapshots(for timelineId: UUID) async throws -> [TurnSnapshot] {
        messages
            .filter { $0.timelineId == timelineId && $0.role == "assistant" }
            .compactMap { msg in
                guard let data = msg.snapshotData else { return nil }
                return try? SerializationUtils.jsonDecoder.decode(TurnSnapshot.self, from: data)
            }
    }
}
