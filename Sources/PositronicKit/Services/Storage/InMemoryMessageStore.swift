import Foundation
import PKContracts
import PKUtilities

/// Thread-safe in-memory message store for prototyping and development.
public actor InMemoryMessageStore: ThreadMessageStoreProtocol {
    private var messages: [ThreadMessage] = []

    public init() {}

    public func saveMessage(_ message: ThreadMessage) async throws {
        messages.append(message)
    }

    public func fetchMessages(for threadID: UUID) async throws -> [ThreadMessage] {
        messages.filter { $0.threadID == threadID }
    }

    public func deleteMessages(for threadID: UUID) async throws {
        messages.removeAll { $0.threadID == threadID }
    }

    public func pruneMessages(olderThan _: TimeInterval, dryRun _: Bool) async throws -> Int {
        0
    }

    public func fetchSnapshots(for threadID: UUID) async throws -> [TurnSnapshot] {
        messages
            .filter { $0.threadID == threadID && $0.role == "assistant" }
            .compactMap { msg in
                guard let data = msg.snapshotData else { return nil }
                return try? SerializationUtils.jsonDecoder.decode(TurnSnapshot.self, from: data)
            }
    }

    package func allMessages() -> [ThreadMessage] {
        messages
    }

    package func replaceMessages(_ messages: [ThreadMessage]) {
        self.messages = messages
    }
}
