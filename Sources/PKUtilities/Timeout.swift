import ErrorKit
import Foundation
import PKContracts

/// A validated wall-clock timeout duration with overflow-safe nanosecond conversion.
///
/// Rejects negative, NaN, and infinite values at construction with a typed
/// `TimeoutValidationError` rather than letting them propagate into
/// `Task.sleep(nanoseconds:)` (where `UInt64(infinity * 1_000_000_000)` would trap)
/// or into a zero-delay immediate-return (where a negative timeout would masquerade as
/// "no timeout"). The nanosecond representation is clamped to `UInt64.max` so
/// huge-but-finite values do not overflow on conversion.
///
/// Use this type wherever a `TimeInterval` timeout would previously have been
/// converted to nanoseconds without validation (PKRR-030).
public struct Timeout: Sendable, Equatable {
    /// The timeout in seconds. Guaranteed finite and non-negative.
    public let seconds: TimeInterval

    /// Constructs a validated timeout.
    /// - Parameter seconds: The timeout duration in seconds. Must be finite and non-negative.
    /// - Throws: `TimeoutValidationError` if `seconds` is negative, NaN, or infinite.
    public init(seconds: TimeInterval) throws {
        guard seconds.isFinite else {
            throw TimeoutValidationError.nonFinite(seconds)
        }
        guard seconds >= 0 else {
            throw TimeoutValidationError.negative(seconds)
        }
        self.seconds = seconds
    }

    /// Nanosecond representation, clamped to `UInt64.max` to avoid overflow traps.
    public var nanoseconds: UInt64 {
        Timeout.nanoseconds(for: seconds)
    }

    /// Overflow-safe nanosecond conversion for a raw delay, clamping to `UInt64.max`.
    /// Negative or non-finite values produce `0` rather than trapping; callers needing
    /// strict validation should use ``init(seconds:)`` instead.
    public static func nanoseconds(for delay: TimeInterval) -> UInt64 {
        guard delay.isFinite, delay >= 0 else { return 0 }
        let maxSecondsBeforeOverflow = TimeInterval(UInt64.max) / 1_000_000_000
        if delay >= maxSecondsBeforeOverflow { return UInt64.max }
        return UInt64(delay * 1_000_000_000)
    }
}

/// Validation errors for ``Timeout`` construction (PKRR-030).
public enum TimeoutValidationError: PKError, Sendable, Equatable {
    /// The timeout was NaN or infinite.
    case nonFinite(TimeInterval)
    /// The timeout was negative.
    case negative(TimeInterval)

    public var errorDomain: String { PKErrorDomain.utilities }

    public var errorCode: Int {
        switch self {
        case .nonFinite: return 5101
        case .negative: return 5102
        }
    }

    public var userFriendlyMessage: String {
        switch self {
        case let .nonFinite(value):
            return "Timeout value \(value) is not a finite number."
        case let .negative(value):
            return "Timeout value \(value) is negative; timeouts must be non-negative."
        }
    }

    public var remediation: String? {
        "Provide a finite, non-negative timeout value (in seconds)."
    }
}
