import Foundation

/// Fully assembled prompt artifact with ordered concrete sections ready for rendering.
public struct AssembledPrompt: Sendable {
    public let resolvedSections: [ResolvedPromptSection]
    public let compressionReport: CompressionReport?

    public init(
        resolvedSections: [ResolvedPromptSection],
        compressionReport: CompressionReport? = nil
    ) {
        precondition(
            duplicateSectionIDs(in: resolvedSections).isEmpty,
            "Duplicate resolved context section ids: \(duplicateSectionIDs(in: resolvedSections).joined(separator: ", "))"
        )
        self.resolvedSections = AssembledPrompt.sortResolvedSections(resolvedSections)
        self.compressionReport = compressionReport
    }

    public func resolveSections() -> [ResolvedPromptSection] {
        resolvedSections
    }

    public func render() async -> String {
        let parts = await renderParts()
        return joinedRenderedParts(parts)
    }

    public func renderAll() async -> [String: String] {
        var result: [String: String] = [:]
        for section in resolvedSections {
            if let content = await section.render(), !content.isEmpty {
                result[section.id] = content
            }
        }
        return result
    }

    public func render(preRendered: [String: String]) async -> String {
        let parts = resolvedSections.compactMap { section in
            preRendered[section.id]
        }
        return joinedRenderedParts(parts)
    }

    @available(*, deprecated, renamed: "renderAll")
    public func structuredContext() async -> [String: String] {
        await renderAll()
    }

    public var estimatedTokens: Int {
        resolvedSections.reduce(0) { $0 + $1.estimatedTokens }
    }

    private func renderParts() async -> [String] {
        var parts: [String] = []
        for section in resolvedSections {
            if let content = await section.render(), !content.isEmpty {
                parts.append(content)
            }
        }
        return parts
    }

    private func joinedRenderedParts(_ parts: [String]) -> String {
        parts.joined(separator: "\n\n---\n\n")
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
