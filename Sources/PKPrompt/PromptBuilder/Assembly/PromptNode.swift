import Foundation

/// Canonical structural prompt IR used before section resolution.
public struct PromptNode: Sendable {
    /// The two structural shapes a prompt node can take.
    package enum NodeType {
        /// A concrete primitive leaf that can materialize a prompt section.
        case leaf(any PromptPrimitive)

        /// A transparent grouping node containing child prompt nodes.
        case fork([PromptNode])
    }

    /// Optional path segment contributed by this node to descendant sections.
    package let pathComponent: String?

    /// Traits inherited by this node's descendants during resolution.
    package let traits: PromptTraits

    /// Structural payload for this node.
    package let nodeType: NodeType

    /// Creates a prompt node with optional path and inherited traits.
    package init(
        pathComponent: String? = nil,
        traits: PromptTraits = PromptTraits(),
        _ nodeType: NodeType
    ) {
        self.pathComponent = pathComponent
        self.traits = traits
        self.nodeType = nodeType
    }

    /// Priority override carried by this node, if any.
    package var priority: Int? { traits.priority }

    /// Compression override carried by this node, if any.
    package var compression: CompressionStrategy? { traits.compression }

    /// Cache policy override carried by this node, if any.
    package var cachePolicy: CachePolicy? { traits.cachePolicy }

    /// Resolves this node and all descendants into concrete prompt sections.
    package func resolve(in context: PromptResolutionContext) -> [PromptSection] {
        let resolvedContext = context
            .descending(into: pathComponent)
            .applying(traits)

        switch nodeType {
        case let .leaf(primitive):
            return [primitive.makeSection(in: resolvedContext)]
        case let .fork(children):
            return children.flatMap { $0.resolve(in: resolvedContext) }
        }
    }
}
