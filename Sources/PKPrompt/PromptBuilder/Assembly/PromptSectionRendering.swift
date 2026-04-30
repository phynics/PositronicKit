import Foundation
import PKShared

public extension Array where Element == PromptSection {
    /// Renders prompt sections once and returns the canonical rendered prompt product.
    func renderPrompt(compressionReport: CompressionReport? = nil) async -> RenderedPrompt {
        var renderedSections: [RenderedPromptSection] = []
        var sectionsByID: [String: String] = [:]
        var stringParts: [String] = []

        for section in self {
            guard let renderedSection = await section.rendered() else {
                continue
            }
            renderedSections.append(renderedSection)

            guard let text = renderedTextContent(for: renderedSection), !text.isEmpty else {
                continue
            }

            sectionsByID[renderedSection.id] = text
            stringParts.append(text)
        }

        return RenderedPrompt(
            sections: renderedSections,
            string: stringParts.joined(separator: "\n\n---\n\n"),
            sectionsByID: sectionsByID,
            compressionReport: compressionReport
        )
    }

    private func renderedTextContent(for section: RenderedPromptSection) -> String? {
        switch section.content {
        case let .text(content):
            return content
        case let .messages(messages):
            let content = messages
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
