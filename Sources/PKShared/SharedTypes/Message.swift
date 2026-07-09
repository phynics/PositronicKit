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
    public var reasoning: String?

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

    /// Completion status of an assistant message.
    ///
    /// `nil` is semantically equivalent to `.complete`: a message persisted through the normal
    /// success path is not tagged, so existing rows (and any decode of legacy data that omits
    /// the key) round-trip as complete. Only failure/cancellation partial turns are tagged —
    /// see `ChatEngine.persistPartialAssistantIfNeeded` (STAB-1).
    public var status: MessageStatus?

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
        reasoning: String? = nil,
        toolCalls: [ToolCall]? = nil,
        toolCallId: String? = nil,
        parentId: UUID? = nil,
        recalledMemories: [Memory]? = nil,
        isSummary: Bool = false,
        summaryType: SummaryType? = nil,
        status: MessageStatus? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.content = content
        self.role = role
        self.reasoning = reasoning
        self.toolCalls = toolCalls
        self.toolCallId = toolCallId
        self.parentId = parentId
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
