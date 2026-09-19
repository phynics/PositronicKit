import Foundation
import PKContracts
import PKUtilities

/// Controls when and whether a candidate memory is actually persisted.
///
/// Host-facing vocabulary: the runtime never saves memories itself. An Agent context source or a
/// host memory pipeline applies the policy when it writes a candidate memory, which is why no
/// runtime code references this type.
public enum MemorySavePolicy: Sendable {
    /// Persist the memory right away.
    case immediate
    /// Defer persistence to a later batching point rather than saving synchronously.
    case deferred
    /// Persist only if no existing memory is at least `threshold` similar to the candidate,
    /// avoiding near-duplicate entries.
    case deduplicating(threshold: Double)
}
