import Foundation
import OpenAI
import PKPrompt
import PKShared

public extension Prompt {
    func toMessages(preRendered: [String: String]? = nil) async -> [ChatQuery.ChatCompletionMessageParam] {
        let resolved = await resolveSections()
        var messages: [ChatQuery.ChatCompletionMessageParam] = []

        if let systemMessage = await buildSystemMessage(from: resolved, preRendered: preRendered) {
            messages.append(systemMessage)
        }

        messages.append(contentsOf: buildHistoryMessages(from: resolved))

        if let queryMessage = await buildUserQueryMessage(from: resolved, preRendered: preRendered) {
            messages.append(queryMessage)
        }

        return messages
    }

    private func resolvedContent(
        for section: ResolvedContextSection,
        using cache: [String: String]?
    ) async -> String? {
        if let cache {
            return cache[section.id]
        }
        return await section.render()
    }

    private func buildSystemMessage(
        from sections: [ResolvedContextSection],
        preRendered: [String: String]? = nil
    ) async -> ChatQuery.ChatCompletionMessageParam? {
        var systemParts: [String] = []

        for section in sections where section.role != .chatHistory && section.role != .userQuery {
            if let content = await resolvedContent(for: section, using: preRendered), !content.isEmpty {
                systemParts.append(content)
            }
        }

        guard !systemParts.isEmpty else { return nil }
        return .system(.init(content: .textContent(systemParts.joined(separator: "\n\n---\n\n")), name: nil))
    }

    private func buildHistoryMessages(from sections: [ResolvedContextSection]) -> [ChatQuery.ChatCompletionMessageParam] {
        sections
            .filter { $0.role == .chatHistory }
            .flatMap { $0.historyMessages ?? [] }
            .map(convertHistoryMessage)
    }

    private func buildUserQueryMessage(
        from sections: [ResolvedContextSection],
        preRendered: [String: String]? = nil
    ) async -> ChatQuery.ChatCompletionMessageParam? {
        guard let querySection = sections.first(where: { $0.role == .userQuery }) else {
            return nil
        }

        guard let content = await resolvedContent(for: querySection, using: preRendered) else {
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
