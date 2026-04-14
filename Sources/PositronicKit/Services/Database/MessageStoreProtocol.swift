import PKShared

// Protocol for managing chat history and message persistence.

import Foundation

public protocol MessageStoreProtocol: Sendable {
    func saveMessage(_ message: ConversationMessage) async throws
    func fetchMessages(for timelineId: UUID) async throws -> [ConversationMessage]
    func deleteMessages(for timelineId: UUID) async throws
    func pruneMessages(olderThan timeInterval: TimeInterval, dryRun: Bool) async throws -> Int
    func fetchSnapshots(for timelineId: UUID) async throws -> [TurnSnapshot]
}
