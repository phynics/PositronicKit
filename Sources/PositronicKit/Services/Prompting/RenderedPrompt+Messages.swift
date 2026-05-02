import Foundation
import PKPrompt
import PKShared

public extension RenderedPrompt {
    /// Builds provider-neutral conversation messages from the canonical rendered prompt product.
    func buildConversationMessages() -> [Message] {
        var messages: [Message] = []

        if let systemMessage = buildSystemConversationMessage(from: sections) {
            messages.append(systemMessage)
        }

        messages.append(contentsOf: buildHistoryConversationMessages(from: sections))

        if let queryMessage = buildUserQueryConversationMessage(from: sections) {
            messages.append(queryMessage)
        }

        return messages
    }

    private func buildSystemConversationMessage(from sections: [Section]) -> Message? {
        var systemParts: [String] = []

        for section in sections where section.role != .chatHistory && section.role != .userQuery {
            if case let .text(content) = section.content, !content.isEmpty {
                systemParts.append(content)
            }
        }

        guard !systemParts.isEmpty else { return nil }
        return Message(content: systemParts.joined(separator: "\n\n---\n\n"), role: .system)
    }

    private func buildHistoryConversationMessages(from sections: [Section]) -> [Message] {
        sections.flatMap { section -> [Message] in
            guard case let .messages(messages) = section.content else {
                return []
            }
            return messages
        }
    }

    private func buildUserQueryConversationMessage(from sections: [Section]) -> Message? {
        guard let querySection = sections.first(where: { $0.role == .userQuery }) else {
            return nil
        }
        guard case let .text(content) = querySection.content, !content.isEmpty else {
            return nil
        }
        return Message(content: content, role: .user)
    }
}
