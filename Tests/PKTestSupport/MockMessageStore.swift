import Foundation
import PositronicKit
import PKShared
import Synchronization

public final class MockMessageStore: MessageStoreProtocol, @unchecked Sendable {
    private let messagesState = Mutex<[ConversationMessage]>([])

    public var messages: [ConversationMessage] {
        get { messagesState.withLock { $0 } }
        set { messagesState.withLock { $0 = newValue } }
    }

    public init() {}

    public func saveMessage(_ message: ConversationMessage) async throws {
        messagesState.withLock {
            $0.append(message)
        }
    }

    public func fetchMessages(for timelineId: UUID) async throws -> [ConversationMessage] {
        messagesState.withLock {
            $0.filter { $0.timelineId == timelineId }
        }
    }

    public func deleteMessages(for timelineId: UUID) async throws {
        messagesState.withLock {
            $0.removeAll { $0.timelineId == timelineId }
        }
    }

    public func pruneMessages(olderThan _: TimeInterval, dryRun _: Bool) async throws -> Int {
        return 0
    }

    public func fetchSnapshots(for timelineId: UUID) async throws -> [TurnSnapshot] {
        messagesState.withLock {
            $0
                .filter { $0.timelineId == timelineId && $0.role == "assistant" }
                .compactMap { message in
                    guard let data = message.snapshotData else { return nil }
                    return try? SerializationUtils.jsonDecoder.decode(TurnSnapshot.self, from: data)
                }
        }
    }
}
