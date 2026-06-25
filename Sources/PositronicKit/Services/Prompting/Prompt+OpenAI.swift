import Foundation
import PKPrompt
import PKShared

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
        guard let systemText = projection.systemText else { return nil }
        return LLMMessage(role: .system, content: systemText)
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
        if let think = msg.think {
            messageContent = "<think>\(think)</think>\n\(messageContent)"
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

        return LLMMessage(role: .assistant, content: messageContent, toolCalls: toolCalls)
    }

    private func buildToolResponseMessage(_ msg: Message) -> LLMMessage {
        let hiddenInstruction = "\n[System: This is a system message hidden from user; now respond to the user about this result.]"
        let responseContent = "<tool_response>\n\(msg.content)\n</tool_response>\(hiddenInstruction)"
        return LLMMessage(role: .user, content: responseContent)
    }
}
