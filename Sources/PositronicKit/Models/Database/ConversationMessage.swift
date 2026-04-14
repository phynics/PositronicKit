import Foundation
import PKShared

/// Individual message within a conversation
public struct ConversationMessage: Codable, Identifiable, Sendable {
    public var id: UUID
    public var timelineId: UUID
    public var role: String
    public var content: String
    public var timestamp: Date
    public var recalledMemories: String
    public var parentId: UUID?
    public var think: String?
    public var toolCalls: String
    public var toolCallId: String?

    /// The agent instance that authored this message (nil for human/CLI messages).
    /// Only set on `.assistant` role messages.
    public var agentInstanceId: UUID?

    /// Depth counter for cross-agent `timeline_send` recursion guard. Default 0.
    public var remoteDepth: Int

    /// Serialized `TurnSnapshot` JSON for audit trail. Only set on assistant messages.
    public var snapshotData: Data?

    public init(
        id: UUID = UUID(),
        timelineId: UUID,
        role: Message.MessageRole,
        content: String,
        timestamp: Date = Date(),
        recalledMemories: String = "[]",
        parentId: UUID? = nil,
        think: String? = nil,
        toolCalls: String = "[]",
        toolCallId: String? = nil,
        agentInstanceId: UUID? = nil,
        remoteDepth: Int = 0,
        snapshotData: Data? = nil
    ) {
        self.id = id
        self.timelineId = timelineId
        self.role = role.rawValue
        self.content = content
        self.timestamp = timestamp
        self.recalledMemories = recalledMemories
        self.parentId = parentId
        self.think = think
        self.toolCalls = toolCalls
        self.toolCallId = toolCallId
        self.agentInstanceId = agentInstanceId
        self.remoteDepth = remoteDepth
        self.snapshotData = snapshotData
    }

    public var messageRole: Message.MessageRole {
        Message.MessageRole(rawValue: role) ?? .user
    }

    /// Convert to UI Message model
    public func toMessage() -> Message {
        let memories: [Memory]
        if let data = recalledMemories.data(using: .utf8) {
            memories = (try? JSONDecoder().decode([Memory].self, from: data)) ?? []
        } else {
            memories = []
        }

        let calls: [ToolCall]
        if let data = toolCalls.data(using: .utf8) {
            calls = (try? JSONDecoder().decode([ToolCall].self, from: data)) ?? []
        } else {
            calls = []
        }

        return Message(
            id: id,
            timestamp: timestamp,
            content: content,
            role: messageRole,
            think: think,
            toolCalls: calls.isEmpty ? nil : calls,
            toolCallId: toolCallId,
            parentId: parentId,
            recalledMemories: memories.isEmpty ? nil : memories
        )
    }
}
