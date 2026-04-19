import Foundation
import PKShared

/// Fully assembled prompt artifact with ordered concrete sections ready for rendering.
public struct AssembledPrompt: Sendable {
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

    public func render() async -> RenderedPrompt {
        var renderedSections: [RenderedPrompt.Section] = []
        for section in resolvedSections {
            if let content = await section.renderedContent() {
                renderedSections.append(
                    RenderedPrompt.Section(
                        id: section.id,
                        role: section.role,
                        content: content
                    )
                )
            }
        }
        return RenderedPrompt(sections: renderedSections)
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
