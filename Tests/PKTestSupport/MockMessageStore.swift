import Foundation
import PKShared
import PKUtilities
import PositronicKit
import Synchronization

/// In-memory `MessageStoreProtocol` test double backed by a mutex-guarded array.
///
/// Inspectable: `messages` reads/writes the backing store directly, so tests can seed
/// fixtures or assert on saved state. `fetchSnapshots(for:)` decodes `TurnSnapshot` from
/// each assistant message's `snapshotData`, mirroring the real persistence layer's format.
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

    public func fetchMessages(for threadID: UUID) async throws -> [ConversationMessage] {
        messagesState.withLock {
            $0.filter { $0.threadID == threadID }
        }
    }

    public func deleteMessages(for threadID: UUID) async throws {
        messagesState.withLock {
            $0.removeAll { $0.threadID == threadID }
        }
    }

    public func pruneMessages(olderThan _: TimeInterval, dryRun _: Bool) async throws -> Int {
        return 0
    }

    public func fetchSnapshots(for threadID: UUID) async throws -> [TurnSnapshot] {
        messagesState.withLock {
            $0
                .filter { $0.threadID == threadID && $0.role == "assistant" }
                .compactMap { message in
                    guard let data = message.snapshotData else { return nil }
                    return try? SerializationUtils.jsonDecoder.decode(TurnSnapshot.self, from: data)
                }
        }
    }
}
