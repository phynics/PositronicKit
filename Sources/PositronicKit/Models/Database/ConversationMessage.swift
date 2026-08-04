import Foundation
import PKShared
import PKUtilities

/// Individual message within a conversation
public struct ConversationMessage: Codable, Identifiable, Sendable {
    public var id: UUID
    public var timelineID: UUID
    public var role: String
    public var content: String
    public var timestamp: Date
    public var recalledMemories: String
    public var parentID: UUID?
    public var reasoning: String?
    public var toolCalls: String
    public var toolCallID: String?

    /// The agent instance that authored this message (nil for human/CLI messages).
    /// Only set on `.assistant` role messages.
    public var agentInstanceID: UUID?

    /// Depth counter for cross-agent `timeline_send` recursion guard. Default 0.
    public var remoteDepth: Int

    /// Serialized `TurnSnapshot` JSON for audit trail. Only set on assistant messages.
    public var snapshotData: Data?

    /// Completion status of an assistant message. `nil` (the default) is treated as `.complete`
    /// so existing rows round-trip unchanged. Tagged `.partial` / `.failed` / `.cancelled` only
    /// on turns cut short by a stream failure or cancellation (STAB-1).
    public var status: Message.MessageStatus?

    public init(
        id: UUID = UUID(),
        timelineID: UUID,
        role: Message.MessageRole,
        content: String,
        timestamp: Date = Date(),
        recalledMemories: String = "[]",
        parentID: UUID? = nil,
        reasoning: String? = nil,
        toolCalls: String = "[]",
        toolCallID: String? = nil,
        agentInstanceID: UUID? = nil,
        remoteDepth: Int = 0,
        snapshotData: Data? = nil,
        status: Message.MessageStatus? = nil
    ) {
        self.id = id
        self.timelineID = timelineID
        self.role = role.rawValue
        self.content = content
        self.timestamp = timestamp
        self.recalledMemories = recalledMemories
        self.parentID = parentID
        self.reasoning = reasoning
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
        self.agentInstanceID = agentInstanceID
        self.remoteDepth = remoteDepth
        self.snapshotData = snapshotData
        self.status = status
    }

    /// Creates a conversation message using the legacy identifier spellings.
    @available(*, deprecated, message: "Use init(..., timelineID:...parentID:...toolCallID:agentInstanceID:...).")
    public init(
        id: UUID = UUID(),
        timelineId: UUID,
        role: Message.MessageRole,
        content: String,
        timestamp: Date = Date(),
        recalledMemories: String = "[]",
        parentId: UUID? = nil,
        reasoning: String? = nil,
        toolCalls: String = "[]",
        toolCallId: String? = nil,
        agentInstanceId: UUID? = nil,
        remoteDepth: Int = 0,
        snapshotData: Data? = nil,
        status: Message.MessageStatus? = nil
    ) {
        self.init(
            id: id,
            timelineID: timelineId,
            role: role,
            content: content,
            timestamp: timestamp,
            recalledMemories: recalledMemories,
            parentID: parentId,
            reasoning: reasoning,
            toolCalls: toolCalls,
            toolCallID: toolCallId,
            agentInstanceID: agentInstanceId,
            remoteDepth: remoteDepth,
            snapshotData: snapshotData,
            status: status
        )
    }

    /// The timeline identifier using the legacy 3.x spelling.
    @available(*, deprecated, renamed: "timelineID")
    public var timelineId: UUID {
        get { timelineID }
        set { timelineID = newValue }
    }

    /// The parent-message identifier using the legacy 3.x spelling.
    @available(*, deprecated, renamed: "parentID")
    public var parentId: UUID? {
        get { parentID }
        set { parentID = newValue }
    }

    /// The tool-call identifier using the legacy 3.x spelling.
    @available(*, deprecated, renamed: "toolCallID")
    public var toolCallId: String? {
        get { toolCallID }
        set { toolCallID = newValue }
    }

    /// The agent-instance identifier using the legacy 3.x spelling.
    @available(*, deprecated, renamed: "agentInstanceID")
    public var agentInstanceId: UUID? {
        get { agentInstanceID }
        set { agentInstanceID = newValue }
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
            reasoning: reasoning,
            toolCalls: calls.isEmpty ? nil : calls,
            toolCallID: toolCallID,
            parentID: parentID,
            recalledMemories: memories.isEmpty ? nil : memories,
            status: status
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case timelineID = "timelineId"
        case role, content, timestamp, recalledMemories
        case parentID = "parentId"
        case reasoning, toolCalls
        case toolCallID = "toolCallId"
        case agentInstanceID = "agentInstanceId"
        case remoteDepth, snapshotData, status
    }
}
