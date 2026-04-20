import Foundation
import PKShared

public enum PromptSectionValidationError: Error, Sendable, Equatable {
    case duplicateSectionIDs([String])
    case multipleUserQuerySections([String])
}

/// Fully assembled prompt artifact with ordered concrete sections ready for rendering.
public struct AssembledPrompt: Sendable {
    public struct Section: Sendable {
        public let id: String
        public let role: PromptSectionRole
        public let content: RenderedPromptSectionContent
    }

    public let resolvedSections: [ResolvedPromptSection]
    public let compressionReport: CompressionReport?

    public init(
        resolvedSections: [ResolvedPromptSection],
        compressionReport: CompressionReport? = nil,
    ) throws {
        try Self.validatePromptShape(in: resolvedSections)
        self.resolvedSections = AssembledPrompt.sortResolvedSections(resolvedSections)
        self.compressionReport = compressionReport
    }

    public func buildSections() async -> [Section] {
        var renderedSections: [Section] = []
        for section in resolvedSections {
            if let content = await section.renderedContent() {
                renderedSections.append(
                    Section(
                        id: section.id,
                        role: section.role,
                        content: content
                    )
                )
            }
        }
        return renderedSections
    }

    public func buildString() async -> String {
        await buildSections()
            .compactMap(textContent)
            .joined(separator: "\n\n---\n\n")
    }

    public func buildSectionsByID() async -> [String: String] {
        var result: [String: String] = [:]
        for section in await buildSections() {
            if case let .text(content) = section.content, !content.isEmpty {
                result[section.id] = content
            }
        }
        return result
    }

    public var estimatedTokens: Int {
        resolvedSections.reduce(0) { $0 + $1.estimatedTokens }
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
        let duplicateIDs = sections.duplicateIDs(idKeyPath: \.id)
        guard duplicateIDs.isEmpty else {
            throw PromptSectionValidationError.duplicateSectionIDs(duplicateIDs)
        }

        let userQueryIDs = sections
            .filter { $0.role == .userQuery }
            .map(\.id)
            .sorted()

        guard userQueryIDs.count <= 1 else {
            throw PromptSectionValidationError.multipleUserQuerySections(userQueryIDs)
        }
    }

    private func textContent(for section: Section) -> String? {
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

    private func messagesContent(for section: Section) -> [Message]? {
        guard case let .messages(messages) = section.content else {
            return nil
        }
        return messages
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
