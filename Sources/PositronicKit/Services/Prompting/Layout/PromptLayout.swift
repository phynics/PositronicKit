import Foundation
import PKContracts
import PKUtilities

/// The cache tier a layout segment belongs to.
///
/// Tier order is the intended wire order for the tiered prompt layout (#277). #287 preserves
/// the existing assembled section order; the tier is carried so later work can group and
/// breakpoint on it without re-deriving it from section roles.
enum PromptCacheTier: Int, Sendable, CaseIterable {
    /// Content that rarely or never changes between turns.
    case stable
    /// Content that changes occasionally, less often than every turn.
    case semiStable
    /// Prior conversation history.
    case history
    /// Per-Turn context that changes on every round.
    case volatile
    /// The current user query.
    case query
}

/// The rendered payload of one layout segment.
enum PromptLayoutContent: Sendable, Equatable {
    /// Ordered text or multimodal content.
    case text(MessageContent)
    /// Structured chat history.
    case messages([Message])
}

/// One ordered segment of the runtime's provider-facing prompt layout.
struct LayoutSegment: Sendable, Equatable {
    /// Stable segment identifier, shared with the assembled section it came from.
    let id: String
    /// The semantic role the segment plays in the conversation.
    let role: PromptSectionRole
    /// The cache tier the segment belongs to.
    let tier: PromptCacheTier
    /// Rendered content payload.
    let content: PromptLayoutContent
    /// Estimated token count for the segment.
    let estimatedTokens: Int
}

/// The runtime's internal tiered prompt layout.
///
/// Built from the assembled prompt artifact, the layout is the runtime's substrate for provider
/// request construction. It renders provider-neutral messages without depending on the optional
/// `PKPrompt` authoring product.
struct PromptLayout: Sendable {
    /// Ordered layout segments.
    let segments: [LayoutSegment]
    /// Canonical plain-text representation carried over from the assembled prompt.
    let string: String
    /// Plain-text content keyed by segment identifier.
    let sectionsByID: [String: String]
    /// Estimated token count across all segments.
    var estimatedTokens: Int {
        segments.reduce(0) { $0 + $1.estimatedTokens }
    }

    init(segments: [LayoutSegment], string: String, sectionsByID: [String: String]) {
        self.segments = segments
        self.string = string
        self.sectionsByID = sectionsByID
    }

    /// Builds provider-neutral chat messages from the layout.
    func renderMessages() -> [LLMMessage] {
        let projection = PromptLayoutProjection(layout: self)
        var messages: [LLMMessage] = []

        if let systemMessage = projection.buildSystemMessage() {
            messages.append(systemMessage)
        }

        messages.append(contentsOf: projection.historyMessages.map(projection.convertHistoryMessage))

        if let userQueryMessage = projection.buildUserQueryMessage() {
            messages.append(userQueryMessage)
        }

        return messages
    }

    /// Builds provider-neutral timeline messages from the layout.
    func renderTimelineMessages() -> [Message] {
        let projection = PromptLayoutProjection(layout: self)
        var messages: [Message] = []

        if let systemText = projection.systemText {
            messages.append(Message(content: systemText, role: .system))
        }

        messages.append(contentsOf: projection.historyMessages)

        if let userQueryContent = projection.userQueryContent {
            messages.append(Message(content: userQueryContent, role: .user))
        }

        return messages
    }
}

/// Projects a `PromptLayout` into system/history/query parts for message rendering.
private struct PromptLayoutProjection {
    let systemText: String?
    /// Retrieved context (`.context` role segments). Kept separate from `.system` so callers
    /// can inject it below the root system instructions rather than merging it at the same
    /// authority level.
    let contextText: String?
    let historyMessages: [Message]
    let userQueryContent: MessageContent?

    init(layout: PromptLayout) {
        var systemParts: [String] = []
        var contextParts: [String] = []
        var historyMessages: [Message] = []
        var userQueryContent: MessageContent?

        for segment in layout.segments {
            switch segment.role {
            case .chatHistory:
                if case let .messages(messages) = segment.content {
                    historyMessages.append(contentsOf: messages)
                }

            case .userQuery:
                if userQueryContent == nil {
                    switch segment.content {
                    case let .text(content) where !content.text.isEmpty:
                        userQueryContent = content
                    case .text, .messages:
                        break
                    }
                }

            case .system:
                if case let .text(content) = segment.content, !content.text.isEmpty {
                    systemParts.append(content.text)
                }

            case .context:
                if case let .text(content) = segment.content, !content.text.isEmpty {
                    contextParts.append(content.text)
                }
            }
        }

        systemText = systemParts.isEmpty ? nil : systemParts.joined(separator: "\n\n---\n\n")
        contextText = contextParts.isEmpty ? nil : contextParts.joined(separator: "\n\n---\n\n")
        self.historyMessages = historyMessages
        self.userQueryContent = userQueryContent
    }

    func buildSystemMessage() -> LLMMessage? {
        // Policy: retrieved context is injected after root system instructions with an explicit
        // "=== Retrieved Context ===" header so it cannot silently elevate to the same authority
        // as the system prompt.
        var parts: [String] = []
        if let systemText { parts.append(systemText) }
        if let contextText {
            parts.append("=== Retrieved Context ===\n\n\(contextText)")
        }
        guard !parts.isEmpty else { return nil }
        return LLMMessage(role: .system, content: parts.joined(separator: "\n\n---\n\n"))
    }

    func buildUserQueryMessage() -> LLMMessage? {
        guard let userQueryContent else { return nil }
        return LLMMessage(role: .user, content: userQueryContent)
    }

    func convertHistoryMessage(_ msg: Message) -> LLMMessage {
        switch msg.role {
        case .user:
            return LLMMessage(role: .user, content: compactedHistoryContent(msg.messageContent))

        case .assistant:
            return buildAssistantMessage(msg)

        case .system:
            return LLMMessage(role: .system, content: msg.content)

        case .tool:
            return buildToolResponseMessage(msg)

        case .summary:
            return LLMMessage(role: .system, content: msg.content)
        }
    }

    private func compactedHistoryContent(_ content: MessageContent, at date: Date = Date()) -> MessageContent {
        MessageContent(parts: content.parts.flatMap { part in
            guard case let .audio(audio) = part,
                  let continuation = audio.continuation,
                  !continuation.isValid(at: date)
            else { return [part] }
            return audio.transcript.map { [.text($0)] } ?? []
        })
    }

    private func buildAssistantMessage(_ msg: Message) -> LLMMessage {
        let projectedText = msg.messageContent.text
        var messageContent = MessageContent(parts: msg.messageContent.parts.flatMap { part in
            guard case let .audio(audio) = part else { return [part] }
            if let continuation = audio.continuation, continuation.isValid() { return [part] }
            return audio.transcript.map { projectedText.contains($0) ? [] : [.text($0)] } ?? []
        })
        if let reasoning = msg.reasoning {
            messageContent = MessageContent(parts: [.text("<think>\(reasoning)</think>\n")] + messageContent.parts)
        }

        var toolCalls: [LLMToolCall]?
        if let calls = msg.toolCalls, !calls.isEmpty {
            toolCalls = calls.map { call in
                LLMToolCall(
                    id: call.id,
                    name: call.name,
                    arguments: (try? toJsonString(call.arguments)) ?? "{}"
                )
            }
        }

        return LLMMessage(
            role: .assistant,
            content: messageContent,
            toolCalls: toolCalls,
            reasoning: msg.reasoning
        )
    }

    private func buildToolResponseMessage(_ msg: Message) -> LLMMessage {
        let hiddenInstruction = "\n[System: This is a system message hidden from user; now respond to the user about this result.]"
        let responseContent = "<tool_response>\n\(msg.content)\n</tool_response>\(hiddenInstruction)"
        return LLMMessage(role: .user, content: responseContent)
    }
}
