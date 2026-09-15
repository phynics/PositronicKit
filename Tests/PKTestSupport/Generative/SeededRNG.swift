import Foundation

/// Deterministic seeded random-number generator for generative (property-based) suites.
///
/// Issue #155 prefers a small in-repo generator with a fixed seed and a committed corpus
/// over a new package dependency. `SeededRNG` is a SplitMix64 generator: compact,
/// `Sendable`, and fully deterministic for a given seed. Every generative suite uses
/// ``GenerativeConfig/defaultSeed`` unless `PK_GENERATIVE_SEED` overrides it, so a
/// failure is reproducible from the log alone (the suite prints the effective seed).
public struct SeededRNG: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) {
        // SplitMix64 requires non-zero state.
        self.state = seed == 0 ? 0x9E3779B97F4A7C15 : seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    /// Integer in `0..<upperBound` via modulo reduction. Bias is negligible for the
    /// small bounds used in test generation; not suitable for uniformity-sensitive sampling.
    public mutating func nextInt(upperBound: Int) -> Int {
        precondition(upperBound > 0, "SeededRNG.nextInt requires a positive bound")
        return Int(next() % UInt64(upperBound))
    }

    /// Uniform integer in `range`.
    package mutating func nextInt(in range: Range<Int>) -> Int {
        precondition(!range.isEmpty, "SeededRNG.nextInt requires a non-empty range")
        return range.lowerBound + nextInt(upperBound: range.upperBound - range.lowerBound)
    }

    /// Uniform integer in `range` (closed).
    package mutating func nextInt(in range: ClosedRange<Int>) -> Int {
        nextInt(in: range.lowerBound ..< range.upperBound + 1)
    }

    /// Uniform element of a non-empty collection.
    public mutating func nextElement<T>(_ values: [T]) -> T {
        precondition(!values.isEmpty, "SeededRNG.nextElement requires a non-empty array")
        return values[nextInt(upperBound: values.count)]
    }
}

/// Shared bounded configuration for every generative suite (issue #155).
///
/// All limits are small by design: generative suites must be bounded and deterministic
/// under a fixed seed, and they run tagged (`.generative`) off the default gate's
/// critical path (nightly job plus explicit runs).
public enum GenerativeConfig {
    /// Fixed default seed so failures reproduce from the log alone.
    public static let defaultSeed: UInt64 = 0x51EED155

    /// Resolve the effective seed: `PK_GENERATIVE_SEED` wins when set to a valid integer,
    /// otherwise the fixed default. Callers log the returned value with their case count.
    public static func effectiveSeed(environment: [String: String] = ProcessInfo.processInfo.environment) -> UInt64 {
        if let raw = environment["PK_GENERATIVE_SEED"], let parsed = UInt64(raw) {
            return parsed
        }
        return defaultSeed
    }

    /// Default number of generated cases per corpus entry. Small enough for an explicit
    /// run to finish in seconds, large enough to explore split/truncation space.
    public static let defaultCaseCount = 64

    /// Hard upper bound any suite may generate in one run, keeping nightly time boxed.
    public static let maxCaseCount = 512
}
