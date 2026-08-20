import Foundation
import PKContracts

public extension PromptJournalPlan {
    /// Renders this journal plan into provider-neutral conversation messages.
    func buildMessages() -> [Message] {
        PromptJournalMessageRenderer.render(self)
    }
}

package enum PromptJournalMessageRenderer {
    private static let snapshotPreamble = Message(
        content: "[PromptJournal v1] Snapshot entries define the active prompt sections. Later replace or remove updates override earlier entries with the same section id.",
        role: .system,
        isSummary: true
    )

    package static func render(_ plan: PromptJournalPlan) -> [Message] {
        switch plan.emissionMode {
        case .snapshot:
            return [snapshotPreamble]
                + snapshotMessages(for: plan.baseSections)
                + volatileMessages(for: plan.volatileSections)
        case .delta:
            return deltaMessages(for: plan.overlaySections, diff: plan.diff)
                + volatileMessages(for: plan.volatileSections)
        }
    }

    private static func snapshotMessages(for sections: [JournaledPromptSection]) -> [Message] {
        sections.compactMap { section in
            guard let content = journalText(for: section.section.content) else {
                return nil
            }

            return Message(
                content: "<prompt_journal_snapshot id=\"\(section.section.id)\" path=\"\(section.journalPath.joined(separator: "/"))\">\n\(content)\n</prompt_journal_snapshot>",
                role: .system
            )
        }
    }

    private static func deltaMessages(
        for overlaySections: [JournaledPromptSection],
        diff: PromptJournalDiff
    ) -> [Message] {
        let replacements: [Message] = overlaySections.compactMap { section in
            guard let content = journalText(for: section.section.content) else {
                return nil
            }

            let tag = diff.addedSemiStableIDs.contains(section.section.id)
                ? "prompt_journal_add"
                : "prompt_journal_replace"

            return Message(
                content: "<\(tag) id=\"\(section.section.id)\" path=\"\(section.journalPath.joined(separator: "/"))\">\n\(content)\n</\(tag)>",
                role: .system
            )
        }

        let removals = diff.removedSemiStableIDs.map { id in
            Message(content: "<prompt_journal_remove id=\"\(id)\" />", role: .system)
        }

        return replacements + removals
    }

    private static func volatileMessages(for sections: [JournaledPromptSection]) -> [Message] {
        var messages: [Message] = []
        var systemParts: [String] = []
        var userQuery: Message?

        for section in sections {
            switch section.section.role {
            case .chatHistory:
                if case let .messages(history) = section.section.content {
                    messages.append(contentsOf: history)
                }
            case .userQuery:
                if case let .text(content) = section.section.content, !content.isEmpty {
                    userQuery = Message(content: content, role: .user)
                }
                if case let .multimodal(content) = section.section.content {
                    userQuery = Message(content: content, role: .user)
                }
            case .system, .context:
                if case let .text(content) = section.section.content, !content.isEmpty {
                    systemParts.append(content)
                }
            }
        }

        if !systemParts.isEmpty {
            messages.insert(Message(content: systemParts.joined(separator: "\n\n---\n\n"), role: .system), at: 0)
        }
        if let userQuery {
            messages.append(userQuery)
        }
        return messages
    }

    private static func journalText(for content: PromptSection.Content) -> String? {
        switch content {
        case let .text(text):
            return text.isEmpty ? nil : text
        case let .messages(messages):
            let value = messages.map(formatHistoryMessage).joined(separator: "\n\n")
            return value.isEmpty ? nil : value
        case let .multimodal(content):
            return content.text.isEmpty ? nil : content.text
        }
    }

    private static func formatHistoryMessage(_ message: Message) -> String {
        switch message.role {
        case .user:
            return "User: \(message.content)"
        case .assistant:
            if let reasoning = message.reasoning, !reasoning.isEmpty {
                return "Assistant: <think>\(reasoning)</think>\n\(message.content)"
            }
            return "Assistant: \(message.content)"
        case .system:
            return "System: \(message.content)"
        case .tool:
            return "Tool: \(message.content)"
        case .summary:
            return "Summary: \(message.content)"
        }
    }
}
