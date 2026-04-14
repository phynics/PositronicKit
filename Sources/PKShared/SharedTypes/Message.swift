import Foundation

/// UI message model for chat interface.
///
/// This model is used by clients to display messages in the conversation. It supports
/// Chain of Thought (CoT) reasoning models that use `<think>` tags to show their
/// reasoning process separately from the final answer.
public struct Message: Identifiable, Equatable, Sendable, Codable {
    /// Unique identifier for the message.
    public let id: UUID

    /// The main response content (with `<think>` and `<tool_call>` tags removed for display).
    public var content: String

    /// The role of the message author.
    public var role: MessageRole

    /// The time at which the message was created.
    public let timestamp: Date

    /// Chain of Thought reasoning extracted from `<think>...</think>` blocks.
    /// Only present for models that support reasoning tags (e.g., DeepSeek R1, QwQ).
    public var think: String?

    /// Tool calls extracted from `<tool_call>...</tool_call>` blocks.
    public var toolCalls: [ToolCall]?

    /// ID of the tool call this message is a response to (only for `.tool` role).
    public var toolCallId: String?

    /// Optional ID of the parent message in the conversation forest structure.
    public var parentId: UUID?

    /// Memories that were provided as context for generating this message.
    public var recalledMemories: [Memory]?

    /// Whether this message represents a system summary or truncation notice.
    public var isSummary: Bool

    /// Type of summary (only applicable if `role` is `.summary`).
    public var summaryType: SummaryType?

    /// Represents the role of a message in a conversation.
    public enum MessageRole: String, Sendable, Codable, CaseIterable {
        /// A message from the user.
        case user
        /// A response from the AI assistant.
        case assistant
        /// A system instruction or notification.
        case system
        /// A message containing the output of a tool execution.
        case tool
        /// A system-generated summary of the conversation.
        case summary
    }

    /// Types of conversation summaries.
    public enum SummaryType: String, Codable, Sendable {
        /// A summary marking a specific topic shift.
        case topic
        /// A broad summary of preceding conversation context.
        case broad
    }

    public enum ContextGatheringProgress: String, Sendable, Codable, CaseIterable {
        case augmenting = "Augmenting Query"
        case tagging = "Generating Tags"
        case embedding = "Generating Embedding"
        case searching = "Searching Memories"
        case ranking = "Ranking Results"
        case discoveringNotes = "Discovering Notes"
        case complete = "Context Ready"
    }

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        content: String,
        role: MessageRole,
        think: String? = nil,
        toolCalls: [ToolCall]? = nil,
        toolCallId: String? = nil,
        parentId: UUID? = nil,
        recalledMemories: [Memory]? = nil,
        isSummary: Bool = false,
        summaryType: SummaryType? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.content = content
        self.role = role
        self.think = think
        self.toolCalls = toolCalls
        self.toolCallId = toolCallId
        self.parentId = parentId
        self.recalledMemories = recalledMemories
        self.isSummary = isSummary
        self.summaryType = summaryType
    }

    /// Content cleaned for UI display (removes <tool_call> tags)
    public var displayContent: String {
        MessageParser.displayContent(for: content)
    }
}

// MARK: - Response Parsing

public extension Message {
    /// Parse LLM response and extract thinking tags
    /// - Parameter rawResponse: Raw response from LLM
    /// - Returns: Tuple with content and optional thinking
    static func parseResponse(_ rawResponse: String) -> (content: String, think: String?) {
        MessageParser.parseResponse(rawResponse)
    }
}
