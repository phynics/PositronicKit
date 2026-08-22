import Foundation
import PKContracts

/// Handles deterministic ordering of tagged memories.
public struct ContextRanker: Sendable {
    public init() {}

    /// Orders memories newest-first with a stable UUID tie-breaker.
    public func rankMemories(_ memories: [Memory]) -> [Memory] {
        return memories.sorted { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt {
                return lhs.updatedAt > rhs.updatedAt
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }
}
