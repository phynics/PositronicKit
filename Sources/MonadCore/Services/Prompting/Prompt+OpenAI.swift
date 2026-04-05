import Foundation
import MonadPrompt
import MonadShared
import OpenAI

public extension Prompt {
    /// Convert the assembled prompt into OpenAI chat messages.
    /// - Parameter preRendered: Optional pre-rendered content map from `renderAll()`.
    ///   When provided, sections use this content instead of re-rendering.
    func toMessages(preRendered: [String: String]? = nil) async -> [ChatQuery.ChatCompletionMessageParam] {
        var messages: [ChatQuery.ChatCompletionMessageParam] = []

        let systemMessage = await buildSystemMessage(preRendered: preRendered)
        if let msg = systemMessage { messages.append(msg) }

        let historyMessages = await buildHistoryMessages()
        messages.append(contentsOf: historyMessages)

        let queryMessage = await buildUserQueryMessage(preRendered: preRendered)
        if let msg = queryMessage { messages.append(msg) }

        return messages
    }

    // MARK: - Helpers

    private func resolvedContent(
        for section: ContextSection,
        using cache: [String: String]?
    ) async -> String? {
        if let cache {
            return cache[section.id]
        }
        return await section.render()
    }

    private func buildSystemMessage(
        preRendered: [String: String]? = nil
    ) async -> ChatQuery.ChatCompletionMessageParam? {
        var systemParts: [String] = []

        for section in sections {
            if section.id == "chat_history" || section.id == "user_query" { continue }
            if let content = await resolvedContent(for: section, using: preRendered), !content.isEmpty {
                systemParts.append(content)
            }
        }

        guard !systemParts.isEmpty else { return nil }
        let combinedSystem = systemParts.joined(separator: "\n\n---\n\n")
        return .system(.init(content: .textContent(combinedSystem), name: nil))
    }

    private func buildHistoryMessages() async -> [ChatQuery.ChatCompletionMessageParam] {
        guard let historySection = sections.first(where: { $0.id == "chat_history" }) as? ChatHistory else {
            return []
        }
        return historySection.messages.map { convertHistoryMessage($0) }
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
        let hiddenInstruction =
            "\n[System: This is a system message hidden from user; " +
            "now respond to the user about this result.]"
        let responseContent = "<tool_response>\n\(msg.content)\n</tool_response>\(hiddenInstruction)"
        return .user(.init(content: .string(responseContent), name: nil))
    }

    private func buildUserQueryMessage(
        preRendered: [String: String]? = nil
    ) async -> ChatQuery.ChatCompletionMessageParam? {
        guard let querySection = sections.first(where: { $0.id == "user_query" }) else { return nil }
        guard let content = await resolvedContent(for: querySection, using: preRendered) else { return nil }
        return .user(.init(content: .string(content), name: nil))
    }
}
