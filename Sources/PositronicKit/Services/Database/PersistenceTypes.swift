import Foundation
import PKContracts
import PKUtilities

/// Controls when and whether a candidate memory is actually persisted.
public enum MemorySavePolicy: Sendable {
    /// Persist the memory right away.
    case immediate
    /// Defer persistence to a later batching point rather than saving synchronously.
    case deferred
    /// Persist only if no existing memory is at least `threshold` similar to the candidate,
    /// avoiding near-duplicate entries.
    case deduplicating(threshold: Double)
}
