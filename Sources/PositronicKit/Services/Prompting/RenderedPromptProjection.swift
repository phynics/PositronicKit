import Foundation
import PKPrompt
import PKShared

struct RenderedPromptProjection {
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
