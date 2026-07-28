import Foundation

/// A protocol for persistence stores that can declare whether they survive process restart.
///
/// Conforming types default to `isDurable == false` (in-memory/ephemeral). Durable adapters
/// (GRDB, SwiftData) override to `true`. The single default here — rather than per-protocol
/// defaults — avoids ambiguity for types that conform to multiple store protocols.
public protocol DurabilityAware: Sendable {
    /// Whether this store survives process restart. Defaults to `false` (in-memory/ephemeral);
    /// durable adapters (GRDB, SwiftData) override to `true`.
    var isDurable: Bool { get }
}

public extension DurabilityAware {
    var isDurable: Bool { false }
}
