import Foundation

/// UI message model for chat interface.
///
/// This model is used by clients to display messages in the thread. It supports
/// Chain of Thought (CoT) reasoning models that use `<think>` tags to show their
/// reasoning process separately from the final answer.
public struct Message: Identifiable, Equatable, Sendable, Codable {
    /// Unique identifier for the message.
    public let id: UUID

    /// The canonical ordered message content.
    public var messageContent: MessageContent

    /// The legacy text projection of ``messageContent``.
    public var content: String {
        get { messageContent.text }
        set { messageContent = MessageContent(newValue) }
    }

    /// The role of the message author.
    public var role: MessageRole

    /// The time at which the message was created.
    public let timestamp: Date

    /// Chain of Thought reasoning extracted from `<think>...</think>` blocks.
    /// Only present for models that support reasoning tags (e.g., DeepSeek R1, QwQ).
    public var reasoning: String?

    /// Tool calls extracted from `<tool_call>...</tool_call>` blocks.
    public var toolCalls: [ToolCall]?

    /// ID of the tool call this message is a response to (only for `.tool` role).
    public var toolCallID: String?

    /// Optional ID of the parent message in the thread forest structure.
    public var parentID: UUID?

    /// Memories that were provided as context for generating this message.
    public var recalledMemories: [Memory]?

    /// Whether this message represents a system summary or truncation notice.
    public var isSummary: Bool

    /// Type of summary (only applicable if `role` is `.summary`).
    public var summaryType: SummaryType?

    /// Completion status of an assistant message.
    ///
    /// `nil` is semantically equivalent to `.complete`: a message persisted through the normal
    /// success path is not tagged, so existing rows (and any decode of legacy data that omits
    /// the key) round-trip as complete. Only failure/cancellation partial turns are tagged —
    /// see `TurnEngine.persistPartialAssistantIfNeeded` (STAB-1).
    public var status: MessageStatus?

    /// Represents the role of a message in a thread.
    public enum MessageRole: String, Sendable, Codable, CaseIterable {
        /// A message from the user.
        case user
        /// A response from the AI assistant.
        case assistant
        /// A system instruction or notification.
        case system
        /// A message containing the output of a tool execution.
        case tool
        /// A system-generated summary of the thread.
        case summary
    }

    /// Types of thread summaries.
    public enum SummaryType: String, Codable, Sendable {
        /// A summary marking a specific topic shift.
        case topic
        /// A broad summary of preceding thread context.
        case broad
    }

    /// Completion status of a persisted assistant message.
    ///
    /// Used to distinguish a turn that was cut short (stream failure, cancellation) from one
    /// that finished normally. `nil` (the default) is treated as `.complete` so existing
    /// persistence round-trips unchanged. See STAB-1.
    public enum MessageStatus: String, Codable, Sendable, Hashable, Equatable {
        /// The turn finished normally and the assistant content is complete.
        case complete
        /// The stream failed mid-flight; persisted content is partial.
        case partial
        /// The turn failed outright (provider 4xx/5xx, network drop, idle timeout).
        case failed
        /// The turn was cancelled by the caller.
        case cancelled
    }

    /// Stages of the memory-retrieval context-gathering pipeline, reported via progress
    /// callbacks (e.g. `MemoryRetrievalStage`) so clients can show a live status label
    /// while context is assembled for a turn. The raw value is the human-readable label.
    public enum ContextGatheringProgress: String, Sendable, Codable, CaseIterable {
        /// Rewriting/expanding the raw user query for retrieval.
        case augmenting = "Augmenting Query"
        /// Generating tags used to filter or bias memory search.
        case tagging = "Generating Tags"
        /// Generating the query embedding for similarity search.
        case embedding = "Generating Embedding"
        /// Running the memory similarity search.
        case searching = "Searching Memories"
        /// Ranking/scoring the search results.
        case ranking = "Ranking Results"
        /// Locating relevant notes/documents outside of memory search.
        case discoveringNotes = "Discovering Notes"
        /// Context gathering has finished.
        case complete = "Context Ready"
    }

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        content: String,
        role: MessageRole,
        reasoning: String? = nil,
        toolCalls: [ToolCall]? = nil,
        toolCallID: String? = nil,
        parentID: UUID? = nil,
        recalledMemories: [Memory]? = nil,
        isSummary: Bool = false,
        summaryType: SummaryType? = nil,
        status: MessageStatus? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        messageContent = MessageContent(content)
        self.role = role
        self.reasoning = reasoning
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
        self.parentID = parentID
        self.recalledMemories = recalledMemories
        self.isSummary = isSummary
        self.summaryType = summaryType
        self.status = status
    }

    /// Creates a message with ordered multimodal content.
    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        content: MessageContent,
        role: MessageRole,
        reasoning: String? = nil,
        toolCalls: [ToolCall]? = nil,
        toolCallID: String? = nil,
        parentID: UUID? = nil,
        recalledMemories: [Memory]? = nil,
        isSummary: Bool = false,
        summaryType: SummaryType? = nil,
        status: MessageStatus? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        messageContent = content
        self.role = role
        self.reasoning = reasoning
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
        self.parentID = parentID
        self.recalledMemories = recalledMemories
        self.isSummary = isSummary
        self.summaryType = summaryType
        self.status = status
    }


    /// Content cleaned for UI display (removes <tool_call> tags)
    public var displayContent: String {
        // Pattern to match <tool_call>...</tool_call> tags, optionally wrapped in code blocks
        let pattern = "(?:```(?:xml)?\\s*)?<tool_call>(.*?)</tool_call>(?:\\s*```)?"

        guard
            let regex = try? NSRegularExpression(
                pattern: pattern, options: [.dotMatchesLineSeparators, .caseInsensitive]
            )
        else {
            return content
        }

        let nsString = content as NSString
        return regex.stringByReplacingMatches(
            in: content,
            range: NSRange(location: 0, length: nsString.length),
            withTemplate: ""
        ).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
    }
}

private extension Message {
    enum CodingKeys: String, CodingKey {
        case id, content, contentParts, role, timestamp, reasoning, toolCalls
        case toolCallID = "toolCallId"
        case parentID = "parentId"
        case recalledMemories, isSummary, summaryType, status
    }
}

public extension Message {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
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
        role = try container.decode(MessageRole.self, forKey: .role)
        reasoning = try container.decodeIfPresent(String.self, forKey: .reasoning)
        toolCalls = try container.decodeIfPresent([ToolCall].self, forKey: .toolCalls)
        toolCallID = try container.decodeIfPresent(String.self, forKey: .toolCallID)
        parentID = try container.decodeIfPresent(UUID.self, forKey: .parentID)
        recalledMemories = try container.decodeIfPresent([Memory].self, forKey: .recalledMemories)
        isSummary = try container.decodeIfPresent(Bool.self, forKey: .isSummary) ?? false
        summaryType = try container.decodeIfPresent(SummaryType.self, forKey: .summaryType)
        status = try container.decodeIfPresent(MessageStatus.self, forKey: .status)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(content, forKey: .content)
        if messageContent.requiresContentPartsEncoding {
            try container.encode(messageContent.parts, forKey: .contentParts)
        }
        try container.encode(role, forKey: .role)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encodeIfPresent(reasoning, forKey: .reasoning)
        try container.encodeIfPresent(toolCalls, forKey: .toolCalls)
        try container.encodeIfPresent(toolCallID, forKey: .toolCallID)
        try container.encodeIfPresent(parentID, forKey: .parentID)
        try container.encodeIfPresent(recalledMemories, forKey: .recalledMemories)
        try container.encode(isSummary, forKey: .isSummary)
        try container.encodeIfPresent(summaryType, forKey: .summaryType)
        try container.encodeIfPresent(status, forKey: .status)
    }
}

// MARK: - Response Parsing

public extension Message {
    /// Parse LLM response and extract thinking tags
    ///
    /// Extracts Chain of Thought reasoning from `<think>...</think>` blocks.
    /// Supported by models like:
    /// - DeepSeek R1
    /// - QwQ (Alibaba)
    /// - Other reasoning models
    ///
    /// Example input:
    /// ```
    /// <think>Let me break this down step by step...</think>
    /// The answer is 42.
    /// ```
    ///
    /// Example output:
    /// ```
    /// content: "The answer is 42."
    /// reasoning: "Let me break this down step by step..."
    /// ```
    ///
    /// - Parameter rawResponse: Raw response from LLM
    /// - Returns: Tuple with content and optional reasoning
    static func parseResponse(_ rawResponse: String) -> (content: String, reasoning: String?) {
        // Pattern to match <think>...</think> tags
        let pattern = "<think>(.*?)</think>"

        guard
            let regex = try? NSRegularExpression(
                pattern: pattern, options: .dotMatchesLineSeparators
            )
        else {
            return (rawResponse, nil)
        }

        let nsString = rawResponse as NSString
        let matches = regex.matches(
            in: rawResponse, range: NSRange(location: 0, length: nsString.length)
        )

        // Extract thinking content
        var thinkingText: String?
        if let match = matches.first, match.numberOfRanges > 1 {
            let thinkRange = match.range(at: 1)
            thinkingText = nsString.substring(with: thinkRange).trimmingCharacters(
                in: .whitespacesAndNewlines
            )
        }

        // Remove all <think>...</think> blocks from content
        let cleanContent = regex.stringByReplacingMatches(
            in: rawResponse,
            range: NSRange(location: 0, length: nsString.length),
            withTemplate: ""
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        return (cleanContent, thinkingText)
    }
}
