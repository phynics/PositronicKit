import Foundation

/// Fully assembled prompt artifact with ordered concrete sections ready for rendering.
public struct AssembledPrompt: Sendable {
    public let resolvedSections: [ResolvedPromptSection]
    public let compressionReport: CompressionReport?

    public init(
        resolvedSections: [ResolvedPromptSection],
        compressionReport: CompressionReport? = nil
    ) {
        let duplicateIds = PromptSectionValidator.duplicateIDs(in: resolvedSections)
        precondition(
            duplicateIds.isEmpty,
            "Duplicate resolved context section ids: \(duplicateIds.joined(separator: ", "))"
        )
        self.resolvedSections = AssembledPrompt.sortResolvedSections(resolvedSections)
        self.compressionReport = compressionReport
    }

    public func render() async -> String {
        joinedRenderedParts(await renderAll())
    }

    public func renderAll() async -> [String: String] {
        await renderAll(preRendered: nil)
    }

    private func renderAll(preRendered: [String: String]?) async -> [String: String] {
        var result: [String: String] = [:]
        for section in resolvedSections {
            if let content = await renderedContent(for: section, preRendered: preRendered) {
                result[section.id] = content
            }
        }
        return result
    }

    public func render(preRendered: [String: String]) async -> String {
        joinedRenderedParts(await renderAll(preRendered: preRendered))
    }

    public func resolveSections() -> [ResolvedPromptSection] {
        resolvedSections
    }

    public var estimatedTokens: Int {
        resolvedSections.reduce(0) { $0 + $1.estimatedTokens }
    }

    private func renderedContent(
        for section: ResolvedPromptSection,
        preRendered: [String: String]? = nil
    ) async -> String? {
        let content: String?
        if let cached = preRendered?[section.id] {
            content = cached
        } else {
            content = await section.render()
        }

        guard let content, !content.isEmpty else {
            return nil
        }

        return content
    }

    private func joinedRenderedParts(_ renderedSections: [String: String]) -> String {
        resolvedSections.compactMap { renderedSections[$0.id] }.joined(separator: "\n\n---\n\n")
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
}
