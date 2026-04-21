import Foundation
import OpenAI
import PKPrompt
import PKShared

public extension AssembledPrompt {
    /// Builds OpenAI chat messages from a freshly rendered canonical prompt product.
    ///
    /// Use this overload when no rendered product is already available.
    func buildMessages() async -> [ChatQuery.ChatCompletionMessageParam] {
        buildMessages(from: await rendered())
    }

    /// Builds OpenAI chat messages from an existing canonical rendered prompt product.
    ///
    /// - Parameter rendered: A rendered prompt previously produced by ``AssembledPrompt/rendered()``.
    /// - Returns: Provider message parameters derived from the rendered section list.
    func buildMessages(from rendered: RenderedPrompt) -> [ChatQuery.ChatCompletionMessageParam] {
        let resolved = rendered.sections
        var messages: [ChatQuery.ChatCompletionMessageParam] = []

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
        from sections: [ConcretePromptSection.Rendered]
    ) -> ChatQuery.ChatCompletionMessageParam? {
        var systemParts: [String] = []

        for section in sections where section.role != .chatHistory && section.role != .userQuery {
            if case let .text(content) = section.content, !content.isEmpty {
                systemParts.append(content)
            }
        }

        guard !systemParts.isEmpty else { return nil }
        return .system(.init(content: .textContent(systemParts.joined(separator: "\n\n---\n\n")), name: nil))
    }

    private func buildHistoryMessages(from sections: [ConcretePromptSection.Rendered]) -> [ChatQuery.ChatCompletionMessageParam] {
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
        from sections: [ConcretePromptSection.Rendered]
    ) -> ChatQuery.ChatCompletionMessageParam? {
        guard let querySection = sections.first(where: { $0.role == .userQuery }) else {
            return nil
        }

        guard case let .text(content) = querySection.content else {
            return nil
        }

        return .user(.init(content: .string(content), name: nil))
    }

    private func convertHistoryMessage(_ msg: Message) -> ChatQuery.ChatCompletionMessageParam {
        switch msg.role {
        case .user:
            return .user(.init(content: .string(msg.content), name: nil))

        case .assistant:
            return buildAssistantMessage(msg)

        case .system:
            return .system(.init(content: .textContent(msg.content), name: nil))

        case .tool:
            return buildToolResponseMessage(msg)

        case .summary:
            return .system(.init(content: .textContent(msg.content), name: nil))
        }
    }

    private func buildAssistantMessage(_ msg: Message) -> ChatQuery.ChatCompletionMessageParam {
        var messageContent = msg.content
        if let think = msg.think {
            messageContent = "<think>\(think)</think>\n\(messageContent)"
        }

        var toolCalls: [ChatQuery.ChatCompletionMessageParam.AssistantMessageParam.ToolCallParam]?
        if let calls = msg.toolCalls, !calls.isEmpty {
            toolCalls = calls.map { call in
                .init(
                    id: call.id.uuidString,
                    function: .init(
                        arguments: (try? toJsonString(call.arguments)) ?? "{}",
                        name: call.name
                    )
                )
            }
        }

        return .assistant(.init(content: .textContent(messageContent), name: nil, toolCalls: toolCalls))
    }

    private func buildToolResponseMessage(_ msg: Message) -> ChatQuery.ChatCompletionMessageParam {
        let hiddenInstruction = "\n[System: This is a system message hidden from user; now respond to the user about this result.]"
        let responseContent = "<tool_response>\n\(msg.content)\n</tool_response>\(hiddenInstruction)"
        return .user(.init(content: .string(responseContent), name: nil))
    }
}
