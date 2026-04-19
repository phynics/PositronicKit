import Foundation
import PKShared

public struct RenderedPrompt: Sendable {
    public struct Section: Sendable {
        public let id: String
        public let role: PromptSectionRole
        public let content: RenderedPromptSectionContent
    }

    public let sections: [Section]

    public var joinedText: String {
        sections
            .compactMap(textContent)
            .joined(separator: "\n\n---\n\n")
    }

    public var sectionsByID: [String: String] {
        var result: [String: String] = [:]
        for section in sections {
            if case .text(let content) = section.content, !content.isEmpty {
                result[section.id] = content
            }
        }
        return result
    }
    
    private func textContent(for section: Section) -> String? {
        switch section.content {
        case .text(let content):
            return content
        case .messages(let messages):
            let content =
                messages
                .map(formatHistoryMessage)
                .joined(separator: "\n\n")
            return content.isEmpty ? nil : content
        }
    }

    private func formatHistoryMessage(_ message: Message) -> String {
        switch message.role {
        case .user:
            return "User: \(message.content)"
        case .assistant:
            if let think = message.think, !think.isEmpty {
                return "Assistant: <think>\(think)</think>\n\(message.content)"
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
