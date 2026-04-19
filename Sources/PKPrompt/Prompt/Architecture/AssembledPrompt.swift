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
        var parts: [String] = []
        for section in resolvedSections {
            let content: String?
            if let cached = preRendered[section.id] {
                content = cached
            } else {
                content = await section.render()
            }
            if let content, !content.isEmpty {
                parts.append(content)
            }
        }
        return joinedRenderedParts(parts)
    }

    public func resolveSections() -> [ResolvedPromptSection] {
        resolvedSections
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
