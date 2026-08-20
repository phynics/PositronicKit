import ErrorKit
import Foundation
import PKContracts

/// A validated retry policy configuration with finite ranges, attempt/elapsed budgets,
/// and deterministic jitter injection for tests.
///
/// All numeric inputs are validated at construction: negative, NaN, infinite, or
/// extreme values fail with a typed `RetryConfigurationError` rather than producing
/// immediate loops, excessive sleeps, or `UInt64` conversion traps downstream in
/// `RetryPolicy.retry` (PKRR-030).
///
/// The configuration caps both the computed exponential backoff (via `maxDelay`) and
/// server-advertised `Retry-After` hints (via `maxRetryAfter`), and enforces a total
/// wall-clock elapsed budget (`maxTotalElapsedTime`) so a hostile or buggy server
/// cannot keep the caller retrying indefinitely.
public struct RetryConfiguration: Sendable {
    /// Maximum number of retry attempts.
    public let maxRetries: Int

    /// Base delay in seconds for exponential backoff (`baseDelay * 2^(attempt-1)`).
    public let baseDelay: TimeInterval

    /// Maximum delay applied to any single computed backoff, capping exponential growth.
    public let maxDelay: TimeInterval

    /// Maximum total elapsed wall-clock time across all retries (total budget).
    public let maxTotalElapsedTime: TimeInterval

    /// Maximum server-advertised `Retry-After` to honor, capping hostile hints.
    public let maxRetryAfter: TimeInterval

    /// Jitter strategy applied to computed backoff delays.
    public let jitter: JitterStrategy

    // MARK: Hard caps

    /// Absolute upper bound on `maxRetries` accepted at construction.
    public static let maxRetriesHardCap = 10

    /// Absolute upper bound on `baseDelay` accepted at construction (seconds).
    public static let baseDelayMax: TimeInterval = 60

    // MARK: Defaults

    /// Default cap for computed backoff delays (5 minutes).
    public static let defaultMaxDelay: TimeInterval = 300

    /// Default cap for server `Retry-After` hints (5 minutes).
    public static let defaultMaxRetryAfter: TimeInterval = 300

    /// Default total elapsed-time budget across all retries (10 minutes).
    public static let defaultMaxTotalElapsedTime: TimeInterval = 600

    // MARK: Init

    /// Constructs a validated retry configuration.
    ///
    /// - Parameters:
    ///   - maxRetries: Maximum number of retries. Must be in `0...maxRetriesHardCap`.
    ///   - baseDelay: Base delay in seconds for exponential backoff. Must be finite,
    ///     non-negative, and ≤ `baseDelayMax`.
    ///   - maxDelay: Cap for any single computed delay. Must be finite and non-negative.
    ///   - maxRetryAfter: Cap for server-advertised `Retry-After`. Must be finite and non-negative.
    ///   - maxTotalElapsedTime: Total wall-clock budget across all retries. Must be finite
    ///     and non-negative.
    ///   - jitter: Jitter strategy applied to backoff delays. Defaults to 0–10% random jitter.
    /// - Throws: `RetryConfigurationError` if any value is negative, NaN, infinite, or
    ///   exceeds its hard cap.
    public init(
        maxRetries: Int = 3,
        baseDelay: TimeInterval = 1.0,
        maxDelay: TimeInterval = RetryConfiguration.defaultMaxDelay,
        maxRetryAfter: TimeInterval = RetryConfiguration.defaultMaxRetryAfter,
        maxTotalElapsedTime: TimeInterval = RetryConfiguration.defaultMaxTotalElapsedTime,
        jitter: JitterStrategy = .randomPercent(upTo: 0.1)
    ) throws {
        guard maxRetries >= 0 else {
            throw RetryConfigurationError.negativeMaxRetries(maxRetries)
        }
        guard maxRetries <= RetryConfiguration.maxRetriesHardCap else {
            throw RetryConfigurationError.maxRetriesExceedsHardCap(maxRetries, cap: RetryConfiguration.maxRetriesHardCap)
        }
        try RetryConfiguration.validateDelay(baseDelay, name: "baseDelay")
        guard baseDelay <= RetryConfiguration.baseDelayMax else {
            throw RetryConfigurationError.baseDelayExceedsMax(baseDelay, max: RetryConfiguration.baseDelayMax)
        }
        try RetryConfiguration.validateDelay(maxDelay, name: "maxDelay")
        try RetryConfiguration.validateDelay(maxRetryAfter, name: "maxRetryAfter")
        try RetryConfiguration.validateDelay(maxTotalElapsedTime, name: "maxTotalElapsedTime")

        self.maxRetries = maxRetries
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
        self.maxRetryAfter = maxRetryAfter
        self.maxTotalElapsedTime = maxTotalElapsedTime
        self.jitter = jitter
    }

    /// Default configuration matching pre-PKRR-030 `RetryPolicy.retry` behavior,
    /// with safe caps applied. Equivalent to `maxRetries: 3, baseDelay: 1.0`.
    public static let `default`: RetryConfiguration = {
        do {
            return try RetryConfiguration()
        } catch {
            preconditionFailure("RetryConfiguration.default failed validation: \(error)")
        }
    }()

    // MARK: Validation helper

    private static func validateDelay(_ value: TimeInterval, name: String) throws {
        guard value.isFinite else {
            throw RetryConfigurationError.nonFiniteDelay(name: name, value: value)
        }
        guard value >= 0 else {
            throw RetryConfigurationError.negativeDelay(name: name, value: value)
        }
    }
}

extension RetryConfiguration: Equatable {
    /// Two configurations are equal if their numeric fields match. The jitter strategy
    /// (a closure) is excluded from equality because closures cannot be compared; two
    /// configs with the same numeric fields but different jitter are functionally
    /// equivalent for comparison purposes.
    public static func == (lhs: RetryConfiguration, rhs: RetryConfiguration) -> Bool {
        lhs.maxRetries == rhs.maxRetries
            && lhs.baseDelay == rhs.baseDelay
            && lhs.maxDelay == rhs.maxDelay
            && lhs.maxRetryAfter == rhs.maxRetryAfter
            && lhs.maxTotalElapsedTime == rhs.maxTotalElapsedTime
    }
}

/// Jitter strategy applied to computed retry delays.
///
/// Encapsulated as a struct with a `@Sendable` closure so tests can inject a
/// deterministic jitter (e.g. `.none` or a fixed value) without touching
/// `Double.random`. Production code uses `.randomPercent(upTo:)`.
public struct JitterStrategy: Sendable {
    public let apply: @Sendable (TimeInterval) -> TimeInterval

    public init(apply: @escaping @Sendable (TimeInterval) -> TimeInterval) {
        self.apply = apply
    }

    /// No jitter — returns the delay unchanged. Deterministic; use in tests.
    public static let none = JitterStrategy { delay in delay }

    /// Random jitter in `[0, delay * fraction]` added to the delay.
    /// Defaults to 10% (`fraction = 0.1`), matching pre-PKRR-030 behavior.
    public static func randomPercent(upTo fraction: Double = 0.1) -> JitterStrategy {
        JitterStrategy { delay in
            delay + Double.random(in: 0.0 ... (delay * fraction))
        }
    }
}

/// Validation errors for `RetryConfiguration` construction (PKRR-030).
public enum RetryConfigurationError: PKError, Sendable, Equatable {
    /// `maxRetries` was negative.
    case negativeMaxRetries(Int)
    /// `maxRetries` exceeded the hard cap.
    case maxRetriesExceedsHardCap(Int, cap: Int)
    /// A delay field was NaN or infinite.
    case nonFiniteDelay(name: String, value: TimeInterval)
    /// A delay field was negative.
    case negativeDelay(name: String, value: TimeInterval)
    /// `baseDelay` exceeded the absolute maximum.
    case baseDelayExceedsMax(TimeInterval, max: TimeInterval)

    public var errorDomain: String { PKErrorDomain.utilities }

    public var errorCode: Int {
        switch self {
        case .negativeMaxRetries: return 5001
        case .maxRetriesExceedsHardCap: return 5002
        case .nonFiniteDelay: return 5003
        case .negativeDelay: return 5004
        case .baseDelayExceedsMax: return 5005
        }
    }

    public var userFriendlyMessage: String {
        switch self {
        case let .negativeMaxRetries(value):
            return "maxRetries \(value) is negative; it must be zero or positive."
        case let .maxRetriesExceedsHardCap(value, cap):
            return "maxRetries \(value) exceeds the hard cap of \(cap)."
        case let .nonFiniteDelay(name, value):
            return "Retry delay '\(name)' value \(value) is not a finite number."
        case let .negativeDelay(name, value):
            return "Retry delay '\(name)' value \(value) is negative; delays must be non-negative."
        case let .baseDelayExceedsMax(value, max):
            return "baseDelay \(value) exceeds the maximum allowed base delay of \(max) seconds."
        }
    }

    public var remediation: String? {
        "Provide finite, non-negative values within the documented hard caps for each retry field."
    }
}
