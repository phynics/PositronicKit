import Foundation
import PKShared

/// Defines the stability of a section's content across requests.
/// Used to order sections to maximize LLM prompt caching effectiveness.
public enum CachePolicy: Sendable, Comparable {
    case stable
    case semiStable
    case volatile
}

/// Defines how a section should be handled when the total prompt token budget is exceeded.
public enum CompressionStrategy: Sendable, Equatable {
    case keep
    case truncate(tail: Bool)
    case summarize
    case drop
}

/// Defines the structural nature of a section's content.
public enum ContextSectionType: Sendable {
    case text
    case list
}

public enum PromptSectionRole: Sendable, Equatable {
    case system
    case context
    case userQuery
    case chatHistory
}

public enum PromptPriority: Int, Sendable {
    case low = 25
    case medium = 50
    case high = 75
    case critical = 100
}

public struct ContextSectionResolutionContext: Sendable {
    public let ancestorPath: [String]
    public let inheritedPriority: Int?
    public let inheritedCompression: CompressionStrategy?
    public let inheritedCachePolicy: CachePolicy?

    public init(
        ancestorPath: [String] = ["prompt"],
        inheritedPriority: Int? = nil,
        inheritedCompression: CompressionStrategy? = nil,
        inheritedCachePolicy: CachePolicy? = nil
    ) {
        self.ancestorPath = ancestorPath
        self.inheritedPriority = inheritedPriority
        self.inheritedCompression = inheritedCompression
        self.inheritedCachePolicy = inheritedCachePolicy
    }

    public func descending(into component: String?) -> ContextSectionResolutionContext {
        guard let component, !component.isEmpty else {
            return self
        }

        var path = ancestorPath
        path.append(component)
        return ContextSectionResolutionContext(
            ancestorPath: path,
            inheritedPriority: inheritedPriority,
            inheritedCompression: inheritedCompression,
            inheritedCachePolicy: inheritedCachePolicy
        )
    }

    public func applying(priority: Int? = nil, compression: CompressionStrategy? = nil, cachePolicy: CachePolicy? = nil) -> ContextSectionResolutionContext {
        ContextSectionResolutionContext(
            ancestorPath: ancestorPath,
            inheritedPriority: priority ?? inheritedPriority,
            inheritedCompression: compression ?? inheritedCompression,
            inheritedCachePolicy: cachePolicy ?? inheritedCachePolicy
        )
    }
}

public struct ResolvedContextSection: Sendable {
    public let id: String
    public let role: PromptSectionRole
    public let priority: Int
    public let estimatedTokens: Int
    public let compression: CompressionStrategy
    public let type: ContextSectionType
    public let cachePolicy: CachePolicy
    public let path: [String]
    public let parentID: String?
    public let historyMessages: [Message]?

    private let renderImpl: @Sendable (Int?) async -> String?

    public init(
        id: String,
        role: PromptSectionRole,
        priority: Int,
        estimatedTokens: Int,
        compression: CompressionStrategy,
        type: ContextSectionType,
        cachePolicy: CachePolicy,
        path: [String],
        parentID: String? = nil,
        historyMessages: [Message]? = nil,
        render: @escaping @Sendable (Int?) async -> String?
    ) {
        self.id = id
        self.role = role
        self.priority = priority
        self.estimatedTokens = estimatedTokens
        self.compression = compression
        self.type = type
        self.cachePolicy = cachePolicy
        self.path = path
        self.parentID = parentID
        self.historyMessages = historyMessages
        self.renderImpl = render
    }

    public func render() async -> String? {
        await renderImpl(nil)
    }

    public func render(constrainedTo tokens: Int?) async -> String? {
        await renderImpl(tokens)
    }

    public func constrained(to tokens: Int) -> ResolvedContextSection {
        ResolvedContextSection(
            id: id,
            role: role,
            priority: priority,
            estimatedTokens: min(estimatedTokens, tokens),
            compression: compression,
            type: type,
            cachePolicy: cachePolicy,
            path: path,
            parentID: parentID,
            historyMessages: historyMessages,
            render: { limit in
                await renderImpl(min(limit ?? tokens, tokens))
            }
        )
    }

    public func summarized(_ summary: String, estimatedTokens: Int) -> ResolvedContextSection {
        ResolvedContextSection(
            id: id,
            role: role,
            priority: priority,
            estimatedTokens: estimatedTokens,
            compression: .keep,
            type: .text,
            cachePolicy: cachePolicy,
            path: path,
            parentID: parentID,
            historyMessages: historyMessages,
            render: { _ in summary }
        )
    }

    public func dropped() -> ResolvedContextSection {
        ResolvedContextSection(
            id: id,
            role: role,
            priority: priority,
            estimatedTokens: 0,
            compression: .drop,
            type: type,
            cachePolicy: cachePolicy,
            path: path,
            parentID: parentID,
            historyMessages: historyMessages,
            render: { _ in nil }
        )
    }
}

public protocol ContextSection: Sendable {
    associatedtype Body: ContextSection = NeverSection
    var body: Body { get }
    var sectionPathComponent: String? { get }
    func resolve(in context: ContextSectionResolutionContext) -> [ResolvedContextSection]
}

public extension ContextSection {
    var sectionPathComponent: String? {
        String(describing: Self.self)
    }

    func resolve(in context: ContextSectionResolutionContext = ContextSectionResolutionContext()) -> [ResolvedContextSection] {
        body.resolve(in: context.descending(into: sectionPathComponent))
    }

    func priority(_ value: Int) -> some ContextSection {
        PriorityModifier(content: self, priority: value)
    }

    func priority(_ value: PromptPriority) -> some ContextSection {
        priority(value.rawValue)
    }

    func compression(_ value: CompressionStrategy) -> some ContextSection {
        CompressionModifier(content: self, compression: value)
    }

    func cachePolicy(_ value: CachePolicy) -> some ContextSection {
        CachePolicyModifier(content: self, cachePolicy: value)
    }

    func render() async -> String? {
        let parts = await resolve(in: ContextSectionResolutionContext()).asyncCompactMap { section in
            await section.render()
        }
        guard !parts.isEmpty else {
            return nil
        }
        return parts.joined(separator: "\n\n---\n\n")
    }
}

public protocol PrimitiveContextSection: ContextSection {
    var id: String { get }
    var role: PromptSectionRole { get }
    var priority: Int { get }
    var estimatedTokens: Int { get }
    var compression: CompressionStrategy { get }
    var type: ContextSectionType { get }
    var cachePolicy: CachePolicy { get }
    var historyMessages: [Message]? { get }
    func renderContent() async -> String?
}

public extension PrimitiveContextSection {
    var body: NeverSection {
        NeverSection()
    }

    var sectionPathComponent: String? {
        nil
    }

    var role: PromptSectionRole {
        .context
    }

    var compression: CompressionStrategy {
        .keep
    }

    var type: ContextSectionType {
        .text
    }

    var cachePolicy: CachePolicy {
        .volatile
    }

    var historyMessages: [Message]? {
        nil
    }

    func render() async -> String? {
        await resolve(in: ContextSectionResolutionContext()).first?.render()
    }

    func render(constrainedTo tokens: Int?) async -> String? {
        await resolve(in: ContextSectionResolutionContext()).first?.render(constrainedTo: tokens)
    }

    func resolve(in context: ContextSectionResolutionContext = ContextSectionResolutionContext()) -> [ResolvedContextSection] {
        let effectivePriority = context.inheritedPriority ?? priority
        let effectiveCompression = context.inheritedCompression ?? compression
        let effectiveCachePolicy = context.inheritedCachePolicy ?? cachePolicy
        let path = context.ancestorPath + [cachePolicyPathComponent(for: effectiveCachePolicy), id]

        return [
            ResolvedContextSection(
                id: id,
                role: role,
                priority: effectivePriority,
                estimatedTokens: estimatedTokens,
                compression: effectiveCompression,
                type: type,
                cachePolicy: effectiveCachePolicy,
                path: path,
                historyMessages: historyMessages,
                render: { tokens in
                    await applyRenderConstraint(
                        to: renderContent,
                        tokens: tokens,
                        strategy: effectiveCompression
                    )
                }
            ),
        ]
    }

    private func applyRenderConstraint(
        to renderContent: @escaping @Sendable () async -> String?,
        tokens: Int?,
        strategy: CompressionStrategy
    ) async -> String? {
        guard let tokens else {
            return await renderContent()
        }

        guard let content = await renderContent(), !content.isEmpty else {
            return nil
        }

        let estimated = max(1, content.count / 4)
        guard estimated > tokens else {
            return content
        }

        guard case let .truncate(tail) = strategy else {
            return content
        }

        let charLimit = max(0, tokens * 4)
        guard charLimit > 0 else {
            return nil
        }

        if tail {
            return String(content.prefix(charLimit)) + "\n... [Truncated]"
        }

        return "... [Truncated]\n" + String(content.suffix(charLimit))
    }

    private func cachePolicyPathComponent(for policy: CachePolicy) -> String {
        switch policy {
        case .stable:
            return "stable"
        case .semiStable:
            return "semiStable"
        case .volatile:
            return "volatile"
        }
    }
}

public struct NeverSection: ContextSection {
    public init() {}

    public var body: NeverSection {
        self
    }

    public var sectionPathComponent: String? {
        nil
    }

    public func resolve(in context: ContextSectionResolutionContext) -> [ResolvedContextSection] {
        []
    }
}

public struct SectionGroup: ContextSection {
    public let sections: [any ContextSection]

    public init(_ sections: [any ContextSection] = []) {
        self.sections = sections
    }

    public init(@ContextBuilder _ content: () -> some ContextSection) {
        self.sections = [content()]
    }

    public var body: NeverSection {
        NeverSection()
    }

    public var sectionPathComponent: String? {
        nil
    }

    public func resolve(in context: ContextSectionResolutionContext) -> [ResolvedContextSection] {
        sections.flatMap { $0.resolve(in: context) }
    }
}

public struct EmptySection: ContextSection {
    public init() {}

    public var body: NeverSection {
        NeverSection()
    }

    public var sectionPathComponent: String? {
        nil
    }

    public func resolve(in context: ContextSectionResolutionContext) -> [ResolvedContextSection] {
        []
    }
}

public struct PriorityModifier<Content: ContextSection>: ContextSection {
    let content: Content
    let priority: Int

    public var body: NeverSection {
        NeverSection()
    }

    public var sectionPathComponent: String? {
        nil
    }

    public func resolve(in context: ContextSectionResolutionContext) -> [ResolvedContextSection] {
        content.resolve(in: context.applying(priority: priority))
    }
}

public struct CompressionModifier<Content: ContextSection>: ContextSection {
    let content: Content
    let compression: CompressionStrategy

    public var body: NeverSection {
        NeverSection()
    }

    public var sectionPathComponent: String? {
        nil
    }

    public func resolve(in context: ContextSectionResolutionContext) -> [ResolvedContextSection] {
        content.resolve(in: context.applying(compression: compression))
    }
}

public struct CachePolicyModifier<Content: ContextSection>: ContextSection {
    let content: Content
    let cachePolicy: CachePolicy

    public var body: NeverSection {
        NeverSection()
    }

    public var sectionPathComponent: String? {
        nil
    }

    public func resolve(in context: ContextSectionResolutionContext) -> [ResolvedContextSection] {
        content.resolve(in: context.applying(cachePolicy: cachePolicy))
    }
}

private extension Array {
    func asyncCompactMap<T: Sendable>(_ transform: @escaping @Sendable (Element) async -> T?) async -> [T] {
        var result: [T] = []
        result.reserveCapacity(count)
        for element in self {
            if let value = await transform(element) {
                result.append(value)
            }
        }
        return result
    }
}
