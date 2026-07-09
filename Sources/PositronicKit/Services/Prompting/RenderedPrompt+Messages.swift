import Foundation
import PKPrompt
import PKShared

private struct RenderedPromptProjection {
    let systemText: String?
    /// Retrieved context (`.context` role sections). Kept separate from `.system` so callers
    /// can inject it below the root system instructions rather than merging it at the same
    /// authority level. See `Prompt+OpenAI.swift` for the provider-message projection policy.
    let contextText: String?
    let historyMessages: [Message]
    let userQueryText: String?

    init(prompt: RenderedPrompt) {
        var systemParts: [String] = []
        var contextParts: [String] = []
        var historyMessages: [Message] = []
        var userQueryText: String?

        for section in prompt.sections {
            switch section.role {
            case .chatHistory:
                if case let .messages(messages) = section.content {
                    historyMessages.append(contentsOf: messages)
                }

            case .userQuery:
                if userQueryText == nil,
                   case let .text(content) = section.content,
                   !content.isEmpty
                {
                    userQueryText = content
                }

            case .system:
                if case let .text(content) = section.content,
                   !content.isEmpty
                {
                    systemParts.append(content)
                }

            case .context:
                if case let .text(content) = section.content,
                   !content.isEmpty
                {
                    contextParts.append(content)
                }
            }
        }

        systemText = systemParts.isEmpty ? nil : systemParts.joined(separator: "\n\n---\n\n")
        contextText = contextParts.isEmpty ? nil : contextParts.joined(separator: "\n\n---\n\n")
        self.historyMessages = historyMessages
        self.userQueryText = userQueryText
    }
}

public extension RenderedPrompt {
    /// Builds provider-neutral conversation messages from the canonical rendered prompt product.
    func buildConversationMessages() -> [Message] {
        let projection = RenderedPromptProjection(prompt: self)
        var messages: [Message] = []

        if let systemMessage = buildSystemConversationMessage(from: projection) {
            messages.append(systemMessage)
        }

        messages.append(contentsOf: buildHistoryConversationMessages(from: projection))

        if let queryMessage = buildUserQueryConversationMessage(from: projection) {
            messages.append(queryMessage)
        }

        return messages
    }

    private func buildSystemConversationMessage(from projection: RenderedPromptProjection) -> Message? {
        guard let systemText = projection.systemText else { return nil }
        return Message(content: systemText, role: .system)
    }

    private func buildHistoryConversationMessages(from projection: RenderedPromptProjection) -> [Message] {
        projection.historyMessages
    }

    private func buildUserQueryConversationMessage(from projection: RenderedPromptProjection) -> Message? {
        guard let userQueryText = projection.userQueryText else { return nil }
        return Message(content: userQueryText, role: .user)
    }
}

public extension RenderedPrompt {
    /// Builds provider-neutral chat messages from the canonical rendered prompt product.
    func buildMessages() -> [LLMMessage] {
        let projection = RenderedPromptProjection(prompt: self)
        var messages: [LLMMessage] = []

        if let systemMessage = buildSystemMessage(from: projection) {
            messages.append(systemMessage)
        }

        messages.append(contentsOf: buildHistoryMessages(from: projection))

        if let queryMessage = buildUserQueryMessage(from: projection) {
            messages.append(queryMessage)
        }

        return messages
    }

    private func buildSystemMessage(
        from projection: RenderedPromptProjection
    ) -> LLMMessage? {
        // Policy: retrieved context is injected after root system instructions with an explicit
        // "=== Retrieved Context ===" header so it cannot silently elevate to the same authority
        // as the system prompt. The header makes the injection visible in both the sent-messages
        // inspector and any provider logs.
        var parts: [String] = []
        if let systemText = projection.systemText { parts.append(systemText) }
        if let contextText = projection.contextText {
            parts.append("=== Retrieved Context ===\n\n\(contextText)")
        }
        guard !parts.isEmpty else { return nil }
        return LLMMessage(role: .system, content: parts.joined(separator: "\n\n---\n\n"))
    }

    private func buildHistoryMessages(from projection: RenderedPromptProjection) -> [LLMMessage] {
        projection.historyMessages.map(convertHistoryMessage)
    }

    private func buildUserQueryMessage(
        from projection: RenderedPromptProjection
    ) -> LLMMessage? {
        guard let userQueryText = projection.userQueryText else { return nil }
        return LLMMessage(role: .user, content: userQueryText)
    }

    private func convertHistoryMessage(_ msg: Message) -> LLMMessage {
        switch msg.role {
        case .user:
            return LLMMessage(role: .user, content: msg.content)

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

    private func buildAssistantMessage(_ msg: Message) -> LLMMessage {
        var messageContent = msg.content
        if let reasoning = msg.reasoning {
            messageContent = "<think>\(reasoning)</think>\n\(messageContent)"
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
