import Foundation
import PKShared

/// Canonical prompt output derived from a single rendering pass.
public struct RenderedPrompt: Sendable {
    /// Rendered sections in canonical prompt order.
    public let sections: [RenderedPromptSection]

    /// Canonical plain-text prompt representation.
    public let string: String

    /// Plain-text content keyed by rendered section identifier.
    public let sectionsByID: [String: String]

    /// Optional compression details captured before rendering.
    public let compressionReport: CompressionReport?

    /// Estimated token count across rendered sections.
    public var estimatedTokens: Int {
        sections.reduce(0) { $0 + $1.estimatedTokens }
    }

    /// Creates a rendered prompt snapshot and its derived projections.
    public init(
        sections: [RenderedPromptSection],
        string: String,
        sectionsByID: [String: String],
        compressionReport: CompressionReport? = nil
    ) {
        self.sections = sections
        self.string = string
        self.sectionsByID = sectionsByID
        self.compressionReport = compressionReport
    }
}

package extension RenderedPrompt {
    static func render(
        sections: [PromptSection],
        compressionReport: CompressionReport? = nil
    ) async -> RenderedPrompt {
        var renderedSections: [RenderedPromptSection] = []
        var sectionsByID: [String: String] = [:]
        var stringParts: [String] = []

        for section in sections {
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

    private static func renderedTextContent(for section: RenderedPromptSection) -> String? {
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

    private static func formatHistoryMessage(_ message: Message) -> String {
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
