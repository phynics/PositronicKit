import Foundation
import PKShared

/// A lightweight cursor for a persisted conversation timeline.
///
/// Conversation values contain no per-turn state. Each value points at the same
/// kit-owned timeline state for its `timelineId`, so callers may freely fetch
/// fresh cursors without changing conversation identity.
public struct Conversation: Identifiable, Sendable {
    public let timelineId: UUID

    public var id: UUID { timelineId }

    /// The shared timeline manager for tier-three operations.
    public var timelineManager: TimelineManager { kit.timelineManager }

    private let kit: PositronicKit

    internal init(timelineId: UUID, kit: PositronicKit) {
        self.timelineId = timelineId
        self.kit = kit
    }

    /// Sends a message through the facade's normal chat-engine execution path.
    public func send(_ message: String) async throws -> AsyncThrowingStream<ChatEvent, Error> {
        try await kit.run(ChatRunRequest(timelineId: timelineId, message: message))
    }
}

public extension PositronicKit {
    /// Creates and persists a new conversation timeline, then returns its cursor.
    func newConversation(title: String = "New Conversation") async throws -> Conversation {
        let timeline = try await timelineManager.createTimeline(title: title)
        return Conversation(timelineId: timeline.id, kit: self)
    }

    /// Returns a fresh cursor for an existing or future timeline id.
    ///
    /// Constructing a cursor does not read from or write to persistence.
    func conversation(timelineId: UUID) -> Conversation {
        Conversation(timelineId: timelineId, kit: self)
    }
}
