import Foundation

package struct PromptNode: Sendable {
    package typealias LeafAssembler = @Sendable (PromptAssembly.Context) -> [PromptSection]

    package let pathComponent: String?
    package let priority: Int?
    package let compression: CompressionStrategy?
    package let cachePolicy: CachePolicy?
    package let children: [PromptNode]
    private let assembleLeaf: LeafAssembler?

    package init(
        pathComponent: String? = nil,
        priority: Int? = nil,
        compression: CompressionStrategy? = nil,
        cachePolicy: CachePolicy? = nil,
        children: [PromptNode] = [],
        assembleLeaf: LeafAssembler? = nil
    ) {
        self.pathComponent = pathComponent
        self.priority = priority
        self.compression = compression
        self.cachePolicy = cachePolicy
        self.children = children
        self.assembleLeaf = assembleLeaf
    }

    package static func group(
        pathComponent: String? = nil,
        priority: Int? = nil,
        compression: CompressionStrategy? = nil,
        cachePolicy: CachePolicy? = nil,
        children: [PromptNode]
    ) -> PromptNode {
        PromptNode(
            pathComponent: pathComponent,
            priority: priority,
            compression: compression,
            cachePolicy: cachePolicy,
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
            priority: priority,
            compression: compression,
            cachePolicy: cachePolicy,
            assembleLeaf: assembleLeaf
        )
    }

    package var isLeaf: Bool {
        assembleLeaf != nil
    }

    package func resolve(in context: PromptAssembly.Context) -> [PromptSection] {
        let resolvedContext = context
            .descending(into: pathComponent)
            .applying(priority: priority, compression: compression, cachePolicy: cachePolicy)

        if let assembleLeaf {
            return assembleLeaf(resolvedContext)
        }

        return children.flatMap { $0.resolve(in: resolvedContext) }
    }
}
