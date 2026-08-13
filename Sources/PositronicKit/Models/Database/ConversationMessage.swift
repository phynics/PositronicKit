import Foundation
import PKShared
import PKUtilities

/// Individual message within a conversation
public struct ConversationMessage: Codable, Identifiable, Sendable {
    public var id: UUID
    public var threadID: UUID
    public var role: String
    public var messageContent: MessageContent
    public var content: String {
        get { messageContent.text }
        set { messageContent = MessageContent(newValue) }
    }
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
        threadID: UUID,
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
        self.threadID = threadID
        self.role = role.rawValue
        messageContent = MessageContent(content)
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

    /// Creates a persisted conversation row with ordered multimodal content.
    public init(
        id: UUID = UUID(),
        threadID: UUID,
        role: Message.MessageRole,
        content: MessageContent,
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
        self.threadID = threadID
        self.role = role.rawValue
        messageContent = content
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

    /// Creates a conversation message using the legacy timeline identifier spelling.
    @available(*, deprecated, message: "Timeline APIs are deprecated and will be removed in v4. Use the corresponding Thread API instead.")
    public init(
        id: UUID = UUID(),
        timelineID: UUID,
        role: Message.MessageRole,
        content: MessageContent,
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
        self.init(
            id: id,
            threadID: timelineID,
            role: role,
            content: content,
            timestamp: timestamp,
            recalledMemories: recalledMemories,
            parentID: parentID,
            reasoning: reasoning,
            toolCalls: toolCalls,
            toolCallID: toolCallID,
            agentInstanceID: agentInstanceID,
            remoteDepth: remoteDepth,
            snapshotData: snapshotData,
            status: status
        )
    }

    /// Creates a conversation message using the legacy identifier spellings.
    @available(*, deprecated, message: "Timeline APIs are deprecated and will be removed in v4. Use the corresponding Thread API instead.")
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
            threadID: timelineId,
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

    /// Creates a conversation message using the legacy identifier spelling.
    @available(*, deprecated, message: "Timeline APIs are deprecated and will be removed in v4. Use the corresponding Thread API instead.")
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
        self.init(
            id: id,
            threadID: timelineID,
            role: role,
            content: content,
            timestamp: timestamp,
            recalledMemories: recalledMemories,
            parentID: parentID,
            reasoning: reasoning,
            toolCalls: toolCalls,
            toolCallID: toolCallID,
            agentInstanceID: agentInstanceID,
            remoteDepth: remoteDepth,
            snapshotData: snapshotData,
            status: status
        )
    }

    /// The thread identifier using the legacy 3.x spelling.
    @available(*, deprecated, message: "Timeline APIs are deprecated and will be removed in v4. Use the corresponding Thread API instead.")
    public var timelineID: UUID {
        get { threadID }
        set { threadID = newValue }
    }

    /// The timeline identifier using the legacy 3.x spelling.
    @available(*, deprecated, message: "Timeline APIs are deprecated and will be removed in v4. Use the corresponding Thread API instead.")
    public var timelineId: UUID {
        get { threadID }
        set { threadID = newValue }
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
            content: messageContent,
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
        case threadID = "timelineId"
        case role, content, contentParts, timestamp, recalledMemories
        case parentID = "parentId"
        case reasoning, toolCalls
        case toolCallID = "toolCallId"
        case agentInstanceID = "agentInstanceId"
        case remoteDepth, snapshotData, status
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        threadID = try container.decode(UUID.self, forKey: .threadID)
        role = try container.decode(String.self, forKey: .role)
        let text = try container.decode(String.self, forKey: .content)
        if let parts = try container.decodeIfPresent([MessageContentPart].self, forKey: .contentParts) {
            let decoded = MessageContent(parts: parts)
            guard decoded.text == text else {
                throw DecodingError.dataCorruptedError(forKey: .contentParts, in: container, debugDescription: "Content parts do not match the text projection.")
            }
            messageContent = decoded
        } else {
            messageContent = MessageContent(text)
        }
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        recalledMemories = try container.decodeIfPresent(String.self, forKey: .recalledMemories) ?? "[]"
        parentID = try container.decodeIfPresent(UUID.self, forKey: .parentID)
        reasoning = try container.decodeIfPresent(String.self, forKey: .reasoning)
        toolCalls = try container.decodeIfPresent(String.self, forKey: .toolCalls) ?? "[]"
        toolCallID = try container.decodeIfPresent(String.self, forKey: .toolCallID)
        agentInstanceID = try container.decodeIfPresent(UUID.self, forKey: .agentInstanceID)
        remoteDepth = try container.decodeIfPresent(Int.self, forKey: .remoteDepth) ?? 0
        snapshotData = try container.decodeIfPresent(Data.self, forKey: .snapshotData)
        status = try container.decodeIfPresent(Message.MessageStatus.self, forKey: .status)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(threadID, forKey: .threadID)
        try container.encode(role, forKey: .role)
        try container.encode(content, forKey: .content)
        if messageContent.requiresContentPartsEncoding {
            try container.encode(messageContent.parts, forKey: .contentParts)
        }
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(recalledMemories, forKey: .recalledMemories)
        try container.encodeIfPresent(parentID, forKey: .parentID)
        try container.encodeIfPresent(reasoning, forKey: .reasoning)
        try container.encode(toolCalls, forKey: .toolCalls)
        try container.encodeIfPresent(toolCallID, forKey: .toolCallID)
        try container.encodeIfPresent(agentInstanceID, forKey: .agentInstanceID)
        try container.encode(remoteDepth, forKey: .remoteDepth)
        try container.encodeIfPresent(snapshotData, forKey: .snapshotData)
        try container.encodeIfPresent(status, forKey: .status)
    }
}
