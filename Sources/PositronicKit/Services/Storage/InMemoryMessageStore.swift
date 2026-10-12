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
            .chronological()
    }
}
