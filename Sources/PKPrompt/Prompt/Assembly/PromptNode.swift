import Foundation

package struct PromptTraits: Sendable {
    package let priority: Int?
    package let compression: CompressionStrategy?
    package let cachePolicy: CachePolicy?

    package init(
        priority: Int? = nil,
        compression: CompressionStrategy? = nil,
        cachePolicy: CachePolicy? = nil
    ) {
        self.priority = priority
        self.compression = compression
        self.cachePolicy = cachePolicy
    }

    package var isEmpty: Bool {
        priority == nil && compression == nil && cachePolicy == nil
    }

    package func applying(
        priority: Int? = nil,
        compression: CompressionStrategy? = nil,
        cachePolicy: CachePolicy? = nil
    ) -> PromptTraits {
        PromptTraits(
            priority: priority ?? self.priority,
            compression: compression ?? self.compression,
            cachePolicy: cachePolicy ?? self.cachePolicy
        )
    }
}

package struct PromptNode: Sendable {
    package typealias LeafAssembler = @Sendable (PromptAssembly.Context) -> [AssembledPrompt.Section]

    package let pathComponent: String?
    package let traits: PromptTraits
    package let children: [PromptNode]
    private let assembleLeaf: LeafAssembler?

    package init(
        pathComponent: String? = nil,
        traits: PromptTraits = PromptTraits(),
        children: [PromptNode] = [],
        assembleLeaf: LeafAssembler? = nil
    ) {
        self.pathComponent = pathComponent
        self.traits = traits
        self.children = children
        self.assembleLeaf = assembleLeaf
    }

    package var priority: Int? { traits.priority }
    package var compression: CompressionStrategy? { traits.compression }
    package var cachePolicy: CachePolicy? { traits.cachePolicy }

    package static func group(
        pathComponent: String? = nil,
        priority: Int? = nil,
        compression: CompressionStrategy? = nil,
        cachePolicy: CachePolicy? = nil,
        children: [PromptNode]
    ) -> PromptNode {
        PromptNode(
            pathComponent: pathComponent,
            traits: PromptTraits(
                priority: priority,
                compression: compression,
                cachePolicy: cachePolicy
            ),
            children: children
        )
    }

    package static func leaf(
        pathComponent: String? = nil,
        priority: Int? = nil,
        compression: CompressionStrategy? = nil,
        cachePolicy: CachePolicy? = nil,
        assembleLeaf: @escaping LeafAssembler
    ) -> PromptNode {
        PromptNode(
            pathComponent: pathComponent,
            traits: PromptTraits(
                priority: priority,
                compression: compression,
                cachePolicy: cachePolicy
            ),
            assembleLeaf: assembleLeaf
        )
    }

    package var isLeaf: Bool {
        assembleLeaf != nil
    }

    package func normalized() -> PromptNode? {
        if let assembleLeaf {
            return PromptNode(
                pathComponent: pathComponent,
                traits: traits,
                assembleLeaf: assembleLeaf
            )
        }

        let normalizedChildren = children.compactMap { $0.normalized() }
        guard !normalizedChildren.isEmpty else {
            return nil
        }

        if pathComponent == nil, traits.isEmpty, normalizedChildren.count == 1 {
            return normalizedChildren[0]
        }

        return PromptNode(
            pathComponent: pathComponent,
            traits: traits,
            children: normalizedChildren
        )
    }

    package func resolve(in context: PromptAssembly.Context) -> [AssembledPrompt.Section] {
        let resolvedContext = context
            .descending(into: pathComponent)
            .applying(traits)

        if let assembleLeaf {
            return assembleLeaf(resolvedContext)
        }

        return children.flatMap { $0.resolve(in: resolvedContext) }
    }
}
