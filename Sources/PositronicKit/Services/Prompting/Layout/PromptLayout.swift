import Foundation
import PKContracts
import PKUtilities

/// The cache tier a layout segment belongs to.
///
/// Tier order is the wire order for the tiered prompt layout (#277):
/// stable system, semi-stable system, history, volatile context, then the query.
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

/// The provider-neutral wire request derived from a `PromptLayout`.
///
/// Carries the rendered messages in tier order plus the cache breakpoints that describe the
/// reusable tiers. The runtime turns the breakpoints into a `PromptCacheDirective`; adapters
/// translate that into provider-native markers (#279).
struct PromptWireLayout: Sendable {
    /// Rendered messages in wire order: stable system, semi-stable system, history, volatile
    /// system, then the user query.
    let messages: [LLMMessage]
    /// Ordered cache breakpoints for the tiers that carry reusable content.
    let breakpoints: [PromptCacheBreakpoint]
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
        wireLayout().messages
    }

    /// The cache breakpoints that describe this layout's reusable tiers.
    ///
    /// At most one breakpoint per tier is emitted, so the result never exceeds the provider
    /// breakpoint cap of four (tools/stable, semi-stable, history, tool loop). A `toolLoop`
    /// breakpoint is added by the caller once a Turn appends tool messages.
    func cacheBreakpoints() -> [PromptCacheBreakpoint] {
        wireLayout().breakpoints
    }

    /// Builds the provider-neutral wire layout: tiered messages plus their cache breakpoints.
    func wireLayout() -> PromptWireLayout {
        let projection = PromptLayoutProjection(layout: self)
        var messages: [LLMMessage] = []

        var stableMessageIndex: Int?
        if let stableText = projection.stableSystemText {
            stableMessageIndex = messages.count
            messages.append(LLMMessage(role: .system, content: stableText))
        }

        var semiStableMessageIndex: Int?
        if let semiStableText = projection.semiStableSystemText {
            semiStableMessageIndex = messages.count
            messages.append(LLMMessage(role: .system, content: semiStableText))
        }

        let historyStart = messages.count
        messages.append(contentsOf: projection.historyMessages.map(projection.convertHistoryMessage))
        let historyEnd = messages.count - 1

        var volatileMessageIndex: Int?
        if let volatileText = projection.volatileSystemText {
            volatileMessageIndex = messages.count
            messages.append(LLMMessage(role: .system, content: volatileText))
        }

        if let userQueryMessage = projection.buildUserQueryMessage() {
            messages.append(userQueryMessage)
        }

        let breakpoints = projection.cacheBreakpoints(
            stableMessageIndex: stableMessageIndex,
            semiStableMessageIndex: semiStableMessageIndex,
            historyRange: historyStart ..< (historyEnd + 1),
            volatilePresent: volatileMessageIndex != nil
        )

        return PromptWireLayout(messages: messages, breakpoints: breakpoints)
    }

    /// Builds provider-neutral timeline messages from the layout.
    ///
    /// Kept aligned with `renderMessages()` so the inspector, persistence, and provider request
    /// agree on message order and tier placement.
    func renderTimelineMessages() -> [Message] {
        let projection = PromptLayoutProjection(layout: self)
        var messages: [Message] = []

        if let stableText = projection.stableSystemText {
            messages.append(Message(content: stableText, role: .system))
        }

        if let semiStableText = projection.semiStableSystemText {
            messages.append(Message(content: semiStableText, role: .system))
        }

        messages.append(contentsOf: projection.historyMessages)

        if let volatileText = projection.volatileSystemText {
            messages.append(Message(content: volatileText, role: .system))
        }

        if let userQueryContent = projection.userQueryContent {
            messages.append(Message(content: userQueryContent, role: .user))
        }

        return messages
    }
}

/// Projects a `PromptLayout` into tiered system/history/query parts for message rendering.
private struct PromptLayoutProjection {
    /// Stable-tier system text (`.system` and `.context` segments with the `.stable` tier).
    let stableSystemText: String?
    /// Semi-stable-tier system text.
    let semiStableSystemText: String?
    /// Volatile-tier system text. Rendered after history so per-Turn context never resets the
    /// stable and semi-stable prefixes.
    let volatileSystemText: String?
    let historyMessages: [Message]
    let userQueryContent: MessageContent?

    let stableTokens: Int
    let semiStableTokens: Int
    let historyTokens: Int
    let toolsTokens: Int

    init(layout: PromptLayout) {
        var stableSystemParts: [String] = []
        var stableContextParts: [String] = []
        var semiStableSystemParts: [String] = []
        var semiStableContextParts: [String] = []
        var volatileSystemParts: [String] = []
        var volatileContextParts: [String] = []
        var historyMessages: [Message] = []
        var userQueryContent: MessageContent?
        var stableTokens = 0
        var semiStableTokens = 0
        var historyTokens = 0
        var toolsTokens = 0

        for segment in layout.segments {
            if segment.id == "tools" {
                toolsTokens = segment.estimatedTokens
            }

            switch segment.role {
            case .chatHistory:
                if case let .messages(messages) = segment.content {
                    historyMessages.append(contentsOf: messages)
                    historyTokens += segment.estimatedTokens
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
                guard case let .text(content) = segment.content, !content.text.isEmpty else { continue }
                Self.appendSystem(content.text, tier: segment.tier, to: &stableSystemParts, &semiStableSystemParts, &volatileSystemParts)
                Self.addTokens(segment.estimatedTokens, tier: segment.tier, &stableTokens, &semiStableTokens)

            case .context:
                guard case let .text(content) = segment.content, !content.text.isEmpty else { continue }
                Self.appendContext(content.text, tier: segment.tier, to: &stableContextParts, &semiStableContextParts, &volatileContextParts)
                Self.addTokens(segment.estimatedTokens, tier: segment.tier, &stableTokens, &semiStableTokens)
            }
        }

        stableSystemText = Self.renderSystemText(
            systemParts: stableSystemParts,
            contextParts: stableContextParts
        )
        semiStableSystemText = Self.renderSystemText(
            systemParts: semiStableSystemParts,
            contextParts: semiStableContextParts
        )
        volatileSystemText = Self.renderSystemText(
            systemParts: volatileSystemParts,
            contextParts: volatileContextParts
        )
        self.historyMessages = historyMessages
        self.userQueryContent = userQueryContent
        self.stableTokens = stableTokens
        self.semiStableTokens = semiStableTokens
        self.historyTokens = historyTokens
        self.toolsTokens = toolsTokens
    }

    /// Renders one tier's system text. `.context` parts carry the explicit
    /// "=== Retrieved Context ===" header so the model can see where injected context came from.
    private static func renderSystemText(systemParts: [String], contextParts: [String]) -> String? {
        var parts: [String] = []
        if !systemParts.isEmpty {
            parts.append(systemParts.joined(separator: "\n\n---\n\n"))
        }
        if !contextParts.isEmpty {
            parts.append("=== Retrieved Context ===\n\n\(contextParts.joined(separator: "\n\n---\n\n"))")
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: "\n\n---\n\n")
    }

    private static func appendSystem(
        _ content: String,
        tier: PromptCacheTier,
        to stable: inout [String],
        _ semiStable: inout [String],
        _ volatile: inout [String]
    ) {
        switch tier {
        case .stable: stable.append(content)
        case .semiStable: semiStable.append(content)
        case .volatile: volatile.append(content)
        case .history, .query: break
        }
    }

    private static func appendContext(
        _ content: String,
        tier: PromptCacheTier,
        to stable: inout [String],
        _ semiStable: inout [String],
        _ volatile: inout [String]
    ) {
        switch tier {
        case .stable: stable.append(content)
        case .semiStable: semiStable.append(content)
        case .volatile: volatile.append(content)
        case .history, .query: break
        }
    }

    private static func addTokens(
        _ tokens: Int,
        tier: PromptCacheTier,
        _ stable: inout Int,
        _ semiStable: inout Int
    ) {
        switch tier {
        case .stable: stable += tokens
        case .semiStable: semiStable += tokens
        case .history, .volatile, .query: break
        }
    }

    /// Builds the ordered breakpoints for the tiers present in this layout.
    ///
    /// Prefix token counts follow Anthropic's request order, where tools precede system. The
    /// semi-stable tier already contains the tool catalog text, so the tools estimate is not
    /// counted twice.
    func cacheBreakpoints(
        stableMessageIndex: Int?,
        semiStableMessageIndex: Int?,
        historyRange: Range<Int>,
        volatilePresent _: Bool
    ) -> [PromptCacheBreakpoint] {
        var breakpoints: [PromptCacheBreakpoint] = []
        var prefixTokens = toolsTokens

        if let stableMessageIndex {
            prefixTokens += stableTokens
            breakpoints.append(PromptCacheBreakpoint(
                messageIndex: stableMessageIndex,
                tier: .stableSystem,
                estimatedPrefixTokens: prefixTokens
            ))
        } else if toolsTokens > 0 {
            // No stable system message: the tools block is the whole reusable prefix.
            breakpoints.append(PromptCacheBreakpoint(
                messageIndex: nil,
                tier: .tools,
                estimatedPrefixTokens: toolsTokens
            ))
        }

        if let semiStableMessageIndex {
            prefixTokens += semiStableTokens - toolsTokens
            breakpoints.append(PromptCacheBreakpoint(
                messageIndex: semiStableMessageIndex,
                tier: .semiStableSystem,
                estimatedPrefixTokens: prefixTokens
            ))
        }

        if !historyRange.isEmpty {
            prefixTokens += historyTokens
            breakpoints.append(PromptCacheBreakpoint(
                messageIndex: historyRange.upperBound - 1,
                tier: .history,
                estimatedPrefixTokens: prefixTokens
            ))
        }

        return breakpoints
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
