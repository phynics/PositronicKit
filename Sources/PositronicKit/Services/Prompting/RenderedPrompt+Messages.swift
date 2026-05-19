import Foundation
import PKPrompt
import PKShared

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
