import Foundation
import PKShared

public struct RenderedPromptSection: Sendable {
    public let id: String
    public let role: PromptSectionRole
    public let content: String?
    public let historyMessages: [Message]?
}

public struct RenderedPrompt: Sendable {
    public let sections: [RenderedPromptSection]
    public let text: String

    public var sectionsByID: [String: String] {
        var result: [String: String] = [:]
        for section in sections {
            if let content = section.content, !content.isEmpty {
                result[section.id] = content
            }
        }
        return result
    }
}

/// Fully assembled prompt artifact with ordered concrete sections ready for rendering.
public struct AssembledPrompt: Sendable {
    public let resolvedSections: [ResolvedPromptSection]
    public let compressionReport: CompressionReport?

    private init(
        resolvedSections: [ResolvedPromptSection],
        compressionReport: CompressionReport? = nil,
        validatedAndSorted: Bool
    ) {
        self.resolvedSections = AssembledPrompt.sortResolvedSections(resolvedSections)
        self.compressionReport = compressionReport
    }

    public static func assemble(
        sections resolvedSections: [ResolvedPromptSection],
        compressionReport: CompressionReport? = nil
    ) throws -> AssembledPrompt {
        try validatePromptShape(in: resolvedSections)
        return AssembledPrompt(
            resolvedSections: resolvedSections,
            compressionReport: compressionReport,
            validatedAndSorted: true
        )
    }

    static func assembleOrPreconditionFailure(
        sections resolvedSections: [ResolvedPromptSection],
        compressionReport: CompressionReport? = nil,
        context: String
    ) -> AssembledPrompt {
        do {
            return try assemble(sections: resolvedSections, compressionReport: compressionReport)
        } catch {
            preconditionFailure("Invalid prompt assembly in \(context): \(error)")
        }
    }

    public func render() async -> RenderedPrompt {
        var renderedSections: [RenderedPromptSection] = []
        for section in resolvedSections {
            let content = await renderedContent(for: section)
            if content != nil || section.role == .chatHistory {
                renderedSections.append(
                    RenderedPromptSection(
                        id: section.id,
                        role: section.role,
                        content: content,
                        historyMessages: section.historyMessages
                    )
                )
            }
        }

        return RenderedPrompt(
            sections: renderedSections,
            text: joinedRenderedParts(renderedSections)
        )
    }

    public var estimatedTokens: Int {
        resolvedSections.reduce(0) { $0 + $1.estimatedTokens }
    }

    private func renderedContent(for section: ResolvedPromptSection) async -> String? {
        if section.role == .chatHistory {
            return renderedHistoryContent(for: section)
        }

        let content = await section.render()
        guard let content, !content.isEmpty else {
            return nil
        }

        return content
    }

    private func renderedHistoryContent(for section: ResolvedPromptSection) -> String? {
        guard let messages = section.historyMessages, !messages.isEmpty else {
            return nil
        }

        let content = messages
            .map(formatHistoryMessage)
            .joined(separator: "\n\n")

        return content.isEmpty ? nil : content
    }

    private func joinedRenderedParts(_ renderedSections: [RenderedPromptSection]) -> String {
        renderedSections
            .compactMap(\.content)
            .joined(separator: "\n\n---\n\n")
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

    static func sortResolvedSections(_ sections: [ResolvedPromptSection]) -> [ResolvedPromptSection] {
        sections.enumerated().sorted { lhs, rhs in
            if lhs.element.cachePolicy != rhs.element.cachePolicy {
                return lhs.element.cachePolicy < rhs.element.cachePolicy
            }
            if lhs.element.priority != rhs.element.priority {
                return lhs.element.priority > rhs.element.priority
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    private static func validatePromptShape(in sections: [ResolvedPromptSection]) throws {
        try PromptSectionValidator.validateUniqueIDs(in: sections)

        let userQueryIDs = sections
            .filter { $0.role == .userQuery }
            .map(\.id)
            .sorted()

        guard userQueryIDs.count <= 1 else {
            throw PromptSectionValidationError.multipleUserQuerySections(userQueryIDs)
        }
    }
}
