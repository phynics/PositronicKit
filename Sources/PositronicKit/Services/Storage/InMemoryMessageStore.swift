import Foundation
import PKContracts
import PKUtilities

/// Timeline-safe in-memory message store for prototyping and development.
public actor InMemoryMessageStore: TimelineMessageStoreProtocol {
    private var messages: [TimelineMessage] = []

    public init() {}

    public func saveMessage(_ message: TimelineMessage) async throws {
        messages.append(message)
    }

    public func fetchMessages(for timelineID: UUID) async throws -> [TimelineMessage] {
        messages
            .filter { $0.timelineID == timelineID }
            .enumerated()
            .sorted { lhs, rhs in
                if lhs.element.timestamp != rhs.element.timestamp {
                    return lhs.element.timestamp < rhs.element.timestamp
                }
                return lhs.offset < rhs.offset
            }
            .map { $0.element }
    }

    public func deleteMessages(for timelineID: UUID) async throws {
        messages.removeAll { $0.timelineID == timelineID }
    }

    public func pruneMessages(olderThan _: TimeInterval, dryRun _: Bool) async throws -> Int {
        0
    }

    public func fetchSnapshots(for timelineID: UUID) async throws -> [TurnSnapshot] {
        messages
            .filter { $0.timelineID == timelineID && $0.role == "assistant" }
            .compactMap { msg in
                guard let data = msg.snapshotData else { return nil }
                return try? SerializationUtils.jsonDecoder.decode(TurnSnapshot.self, from: data)
            }
    }
}
