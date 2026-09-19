import Foundation
import PKContracts
import PKUtilities

/// The runtime policy values that flow from ``PKRuntime/Configuration`` through
/// ``RuntimeDependencies`` into ``TurnEngine/Dependencies``.
///
/// Grouping them means every forwarding site stops re-listing the same names, and the two bounds
/// get a single home: the stream watchdog and the terminal-commit stall limit were previously
/// clamped in two different types. Only `generationParameters` is replaced by a
/// ``PKRuntime/replacingLanguageModel(_:generationParameters:)`` view; the rest are fixed at
/// construction.
///
/// Not part of the public API surface.
internal struct RuntimePolicy: Sendable {
    /// Production default for the per-stream idle watchdog.
    static let defaultStreamTimeout: TimeInterval = 60
    /// Production default for the terminal-commit stall limit (ADR 0010).
    static let defaultTerminalCommitStallLimit: TimeInterval = 300
    /// Bounds that keep unusable idle timeouts out of the stream watchdog. They exist to avoid a
    /// timeout that fails every Turn instantly and one that would overflow `Duration.seconds(_:)`
    /// in `StreamIdleDeadline`, and are deliberately wide so ordinary sub-second timeouts pass
    /// through untouched.
    static let streamTimeoutRange: ClosedRange<TimeInterval> = 0.001...86_400

    /// Maximum idle time, in seconds, between streamed model chunks before a Turn fails with
    /// `streamTimedOut`. Clamped to one millisecond ... one day.
    var streamTimeout: TimeInterval
    /// How long, in seconds, a Turn's terminal commit may stay pending before admission treats
    /// the Turn as abandoned and interrupts it (ADR 0010).
    var terminalCommitStallLimit: TimeInterval
    /// Whether required Turn degradations fail the Turn.
    var degradationPolicy: TurnDegradationPolicy
    /// Controls diagnostic response snapshots.
    var diagnosticSnapshotConfiguration: DiagnosticSnapshotConfiguration
    /// The logging configuration used for runtime diagnostics.
    var loggingConfiguration: LoggingConfiguration
    /// The clock the stream watchdog and stall detection measure against.
    var clock: any RuntimeClock
    /// The default generation parameters applied when a Turn carries no explicit override.
    var generationParameters: GenerationParameters?

    init(
        streamTimeout: TimeInterval = RuntimePolicy.defaultStreamTimeout,
        terminalCommitStallLimit: TimeInterval = RuntimePolicy.defaultTerminalCommitStallLimit,
        degradationPolicy: TurnDegradationPolicy = .failRequired,
        diagnosticSnapshotConfiguration: DiagnosticSnapshotConfiguration = .default,
        loggingConfiguration: LoggingConfiguration = .default,
        clock: any RuntimeClock = ContinuousRuntimeClock(),
        generationParameters: GenerationParameters? = nil
    ) {
        self.streamTimeout = Self.resolvedStreamTimeout(streamTimeout)
        self.terminalCommitStallLimit = Self.resolvedTerminalCommitStallLimit(terminalCommitStallLimit)
        self.degradationPolicy = degradationPolicy
        self.diagnosticSnapshotConfiguration = diagnosticSnapshotConfiguration
        self.loggingConfiguration = loggingConfiguration
        self.clock = clock
        self.generationParameters = generationParameters
    }

    /// A finite idle timeout inside one millisecond ... one day.
    ///
    /// The bounds exist only to keep unusable values out of the stream watchdog: a zero or
    /// negative timeout would fail every Turn the instant it starts, and a huge or infinite one
    /// would trap in `Duration.seconds(_:)`. Out-of-range values are clamped and non-finite ones
    /// fall back to the default.
    static func resolvedStreamTimeout(_ requested: TimeInterval) -> TimeInterval {
        guard requested.isFinite else { return defaultStreamTimeout }
        return min(max(requested, streamTimeoutRange.lowerBound), streamTimeoutRange.upperBound)
    }

    /// A finite, positive stall limit, falling back to the default.
    static func resolvedTerminalCommitStallLimit(_ requested: TimeInterval) -> TimeInterval {
        guard requested.isFinite, requested > 0 else { return defaultTerminalCommitStallLimit }
        return requested
    }
}
