import Foundation

public struct Prompt: Sendable {
    public let sections: [any PromptComposite]
    public let compressionReport: CompressionReport?

    private let resolvedSectionsStorage: [ResolvedPromptSection]?

    public init(sections: [any PromptComposite], compressionReport: CompressionReport? = nil) {
        try? validateUniqueSectionIDs(sections)
        self.sections = sections
        self.compressionReport = compressionReport
        self.resolvedSectionsStorage = nil
    }

    public init(@ContextBuilder _ content: () -> some PromptComposite) {
        self.init(sections: [content()])
    }

    public init(
        sections: [any PromptComposite],
        resolvedSections: [ResolvedPromptSection],
        compressionReport: CompressionReport? = nil
    ) {
        precondition(
            duplicateSectionIDs(in: resolvedSections).isEmpty,
            "Duplicate resolved context section ids: \(duplicateSectionIDs(in: resolvedSections).joined(separator: ", "))"
        )
        self.sections = sections
        self.compressionReport = compressionReport
        self.resolvedSectionsStorage = Prompt.sortResolvedSections(resolvedSections)
    }

    public func resolveSections() async -> [ResolvedPromptSection] {
        if let resolvedSectionsStorage {
            return resolvedSectionsStorage
        }
        return Prompt.sortResolvedSections(sections.flatMap { $0.resolve(in: PromptResolutionContext()) })
    }

    public func render() async -> String {
        let parts = await renderParts()
        return joinedRenderedParts(parts)
    }

    public func renderAll() async -> [String: String] {
        let resolved = await resolveSections()
        var result: [String: String] = [:]
        for section in resolved {
            if let content = await section.render(), !content.isEmpty {
                result[section.id] = content
            }
        }
        return result
    }

    public func render(preRendered: [String: String]) async -> String {
        let resolved = await resolveSections()
        let parts = resolved.compactMap { section in
            preRendered[section.id]
        }
        return joinedRenderedParts(parts)
    }

    @available(*, deprecated, renamed: "renderAll")
    public func structuredContext() async -> [String: String] {
        await renderAll()
    }

    public var estimatedTokens: Int {
        let resolved = resolvedSectionsStorage ?? Prompt.sortResolvedSections(sections.flatMap { $0.resolve(in: PromptResolutionContext()) })
        return resolved.reduce(0) { $0 + $1.estimatedTokens }
    }

    private func renderParts() async -> [String] {
        let resolved = await resolveSections()
        var parts: [String] = []
        for section in resolved {
            if let content = await section.render(), !content.isEmpty {
                parts.append(content)
            }
        }
        return parts
    }

    private func joinedRenderedParts(_ parts: [String]) -> String {
        parts.joined(separator: "\n\n---\n\n")
    }

    private static func sortResolvedSections(_ sections: [ResolvedPromptSection]) -> [ResolvedPromptSection] {
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
