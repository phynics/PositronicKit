import Foundation

// MARK: - Hash Tree

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

/// A structure providing a verifiable, mathematical representation of pipeline state.
public struct HashTree: Sendable {
    public let root: HashTreeNode?
    
    /// The associative state hash.
    /// Because we use associative modular addition, `hash(base + diff) = hash(base) &+ hash(diff)`.
    /// This allows API users to definitively identify the exact structural state of the pipeline.
    public let stateHash: UInt64
    
    public init(entries: [any PipelineSnapshotEntry]) {
        self.root = HashTree.buildTree(entries: entries, bounds: 0..<entries.count)
        self.stateHash = entries.reduce(0) { $0 &+ $1.contentHash }
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
}
