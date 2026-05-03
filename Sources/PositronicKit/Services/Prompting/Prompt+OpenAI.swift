import Foundation
import PKPrompt
import PKShared

public extension RenderedPrompt {
    /// Builds provider-neutral chat messages from the canonical rendered prompt product.
    func buildMessages() -> [LLMMessage] {
        let resolved = sections
        var messages: [LLMMessage] = []

        if let systemMessage = buildSystemMessage(from: resolved) {
            messages.append(systemMessage)
        }

        messages.append(contentsOf: buildHistoryMessages(from: resolved))

        if let queryMessage = buildUserQueryMessage(from: resolved) {
            messages.append(queryMessage)
        }

        return messages
    }

    private func buildSystemMessage(
        from sections: [Section]
    ) -> LLMMessage? {
        var systemParts: [String] = []

        for section in sections where section.role != .chatHistory && section.role != .userQuery {
            if case let .text(content) = section.content, !content.isEmpty {
                systemParts.append(content)
            }
        }

        guard !systemParts.isEmpty else { return nil }
        return LLMMessage(role: .system, content: systemParts.joined(separator: "\n\n---\n\n"))
    }

    private func buildHistoryMessages(from sections: [Section]) -> [LLMMessage] {
        sections
            .flatMap { section -> [Message] in
                guard case let .messages(messages) = section.content else {
                    return []
                }
                return messages
            }
            .map(convertHistoryMessage)
    }

    private func buildUserQueryMessage(
        from sections: [Section]
    ) -> LLMMessage? {
        guard let querySection = sections.first(where: { $0.role == .userQuery }) else {
            return nil
        }

        guard case let .text(content) = querySection.content else {
            return nil
        }

        return LLMMessage(role: .user, content: content)
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
        if let think = msg.think {
            messageContent = "<think>\(think)</think>\n\(messageContent)"
        }

        var toolCalls: [LLMToolCall]?
        if let calls = msg.toolCalls, !calls.isEmpty {
            toolCalls = calls.map { call in
                LLMToolCall(
                    id: call.id.uuidString,
                    name: call.name,
                    arguments: (try? toJsonString(call.arguments)) ?? "{}"
                )
            }
        }

        return LLMMessage(role: .assistant, content: messageContent, toolCalls: toolCalls)
    }

    private func buildToolResponseMessage(_ msg: Message) -> LLMMessage {
        let hiddenInstruction = "\n[System: This is a system message hidden from user; now respond to the user about this result.]"
        let responseContent = "<tool_response>\n\(msg.content)\n</tool_response>\(hiddenInstruction)"
        return LLMMessage(role: .user, content: responseContent)
    }
}
