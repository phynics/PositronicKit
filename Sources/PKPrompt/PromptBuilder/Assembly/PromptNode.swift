import Foundation

package struct PromptNode: Sendable {
    package typealias LeafAssembler = @Sendable (PromptAssembly.Context) -> [AssembledPrompt.Section]

    package enum NodeType {
        case leaf(LeafAssembler)
        case fork([PromptNode])
    }

    package let pathComponent: String?
    package let traits: PromptTraits
    package let nodeType: NodeType

    package init(
        pathComponent: String? = nil,
        traits: PromptTraits = PromptTraits(),
        _ nodeType: NodeType
    ) {
        self.pathComponent = pathComponent
        self.traits = traits
        self.nodeType = nodeType
    }

    package var priority: Int? { traits.priority }
    package var compression: CompressionStrategy? { traits.compression }
    package var cachePolicy: CachePolicy? { traits.cachePolicy }

    package func resolve(in context: PromptAssembly.Context) -> [AssembledPrompt.Section] {
        let resolvedContext = context
            .descending(into: pathComponent)
            .applying(traits)

        switch nodeType {
        case let .leaf(assembleLeaf):
            return assembleLeaf(resolvedContext)
        case let .fork(children):
            return children.flatMap { $0.resolve(in: resolvedContext) }
        }
    }
}
