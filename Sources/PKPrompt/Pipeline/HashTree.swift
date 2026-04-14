import Foundation

// MARK: - Hash Tree

public struct HashTreeHierarchyNode: Sendable {
    public let entryId: String?
    public let path: [String]
    public let parentEntryId: String?
    public let order: Int?
    public let sectionKind: PipelineSnapshotSectionKind?
    public let hash: UInt64
    public let children: [HashTreeHierarchyNode]
}

/// A structural representation of pipeline items that supports associative homomorphic hashing.
public enum HashTreeNode: Sendable {
    case leaf(id: String, hash: UInt64)
    indirect case node(left: HashTreeNode, right: HashTreeNode, hash: UInt64)
    
    public var hash: UInt64 {
        switch self {
        case .leaf(_, let h): return h
        case .node(_, _, let h): return h
        }
    }
}

/// A structure providing an associative structural fingerprint of pipeline state.
public struct HashTree: Sendable {
    public let root: HashTreeNode?
    public let semanticRoots: [HashTreeHierarchyNode]
    
    /// The associative state hash.
    /// Because we use associative modular addition, `hash(base + diff) = hash(base) &+ hash(diff)`.
    /// This is useful as a fast fingerprint, but it is not a cryptographic proof of exact state.
    public let stateHash: UInt64
    
    public init(entries: [any PipelineSnapshotEntry]) {
        self.root = HashTree.buildTree(entries: entries, bounds: 0..<entries.count)
        self.stateHash = entries.reduce(0) { $0 &+ $1.contentHash }
        self.semanticRoots = HashTree.buildSemanticTree(entries: entries)
    }
    
    private static func buildTree(entries: [any PipelineSnapshotEntry], bounds: Range<Int>) -> HashTreeNode? {
        let count = bounds.count
        if count == 0 { return nil }
        if count == 1 {
            let entry = entries[bounds.lowerBound]
            return .leaf(id: entry.entryId, hash: entry.contentHash)
        }
        
        let mid = bounds.lowerBound + count / 2
        let left = buildTree(entries: entries, bounds: bounds.lowerBound..<mid)
        let right = buildTree(entries: entries, bounds: mid..<bounds.upperBound)
        
        if let l = left, let r = right {
            // Using associative wrapping addition so that the tree node hash corresponds to the associative subset sum
            let combinedHash = l.hash &+ r.hash
            return .node(left: l, right: r, hash: combinedHash)
        } else {
            return left ?? right
        }
    }

    private static func buildSemanticTree(entries: [any PipelineSnapshotEntry]) -> [HashTreeHierarchyNode] {
        final class NodeBuilder {
            let key: String
            let path: [String]
            var entryId: String?
            var parentEntryId: String?
            var order: Int?
            var sectionKind: PipelineSnapshotSectionKind?
            var hash: UInt64
            var children: [String: NodeBuilder]

            init(
                key: String,
                path: [String],
                entryId: String? = nil,
                parentEntryId: String? = nil,
                order: Int? = nil,
                sectionKind: PipelineSnapshotSectionKind? = nil,
                hash: UInt64 = 0
            ) {
                self.key = key
                self.path = path
                self.entryId = entryId
                self.parentEntryId = parentEntryId
                self.order = order
                self.sectionKind = sectionKind
                self.hash = hash
                self.children = [:]
            }
        }

        var nodesByPath: [String: NodeBuilder] = [:]
        let root = NodeBuilder(key: "", path: [], sectionKind: .synthetic)
        nodesByPath[root.key] = root

        func key(for path: [String]) -> String {
            path.joined(separator: "/")
        }

        func ensureNode(path: [String]) -> NodeBuilder {
            let nodeKey = key(for: path)
            if let existing = nodesByPath[nodeKey] {
                return existing
            }

            let parentPath = Array(path.dropLast())
            let parent = ensureNode(path: parentPath)
            let builder = NodeBuilder(key: nodeKey, path: path, sectionKind: .synthetic)
            parent.children[nodeKey] = builder
            nodesByPath[nodeKey] = builder
            return builder
        }

        for (index, entry) in entries.enumerated() {
            let entryPath = entry.path.isEmpty ? [entry.entryId] : entry.path
            let builder = ensureNode(path: entryPath)
            builder.entryId = entry.entryId
            builder.parentEntryId = entry.parentEntryId
            builder.order = entry.order
            builder.sectionKind = entry.sectionKind
            builder.hash = entry.contentHash

            for depth in 1..<entryPath.count {
                let prefixPath = Array(entryPath.prefix(depth))
                let prefixKey = key(for: prefixPath)
                if nodesByPath[prefixKey]?.order == nil {
                    nodesByPath[prefixKey]?.order = entry.order ?? index
                }
            }
        }

        for node in nodesByPath.values where !node.path.isEmpty {
            guard node.parentEntryId != nil else { continue }
            let parent = nodesByPath.values.first(where: { $0.entryId == node.parentEntryId })
            guard let parent else { continue }
            let fallbackParentPath = key(for: Array(node.path.dropLast()))
            nodesByPath[fallbackParentPath]?.children.removeValue(forKey: node.key)
            parent.children[node.key] = node
        }

        func freeze(_ builder: NodeBuilder) -> HashTreeHierarchyNode {
            let sortedChildren = builder.children.values.sorted { lhs, rhs in
                let lhsOrder = lhs.order ?? Int.max
                let rhsOrder = rhs.order ?? Int.max
                if lhsOrder != rhsOrder { return lhsOrder < rhsOrder }
                return lhs.path.lexicographicallyPrecedes(rhs.path)
            }

            let frozenChildren = sortedChildren.map(freeze)
            let childrenHash = frozenChildren.reduce(UInt64.zero) { $0 &+ $1.hash }
            let effectiveHash = builder.hash == 0 ? childrenHash : builder.hash
            return HashTreeHierarchyNode(
                entryId: builder.entryId,
                path: builder.path,
                parentEntryId: builder.parentEntryId,
                order: builder.order,
                sectionKind: builder.sectionKind,
                hash: effectiveHash,
                children: frozenChildren
            )
        }

        let topLevelChildren = root.children.values.sorted { lhs, rhs in
            let lhsOrder = lhs.order ?? Int.max
            let rhsOrder = rhs.order ?? Int.max
            if lhsOrder != rhsOrder { return lhsOrder < rhsOrder }
            return lhs.path.lexicographicallyPrecedes(rhs.path)
        }
        return topLevelChildren.map(freeze)
    }
}
