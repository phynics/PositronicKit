import Foundation

/// Bounded wait policy for observing a Turn's terminal state.
///
/// The common path is push-driven: ``TurnEventHub/awaitTerminal(turnID:)`` wakes the waiter the
/// instant the hub observes the Turn finish — no polling. The fallback path exists only for a
/// Turn this process's hub never tracked as active (admitted by another process, or already
/// terminal before the caller asked) and is a single, bounded poll with one explicit timeout
/// policy owned by this type, replacing three previously separate unbounded, differently-tuned
/// poll loops.
struct TurnTerminationWaiter: Sendable {
    /// What ``awaitResult(turnID:fetch:)`` observed.
    enum Observation<Value: Sendable>: Sendable {
        /// The durable terminal value, once observed.
        case value(Value)
        /// Neither the hub nor the fallback poll observed a terminal value within
        /// ``pollTimeout``. The underlying Turn may still be running.
        case timedOut
    }

    /// Default bound for the fallback poll against a Turn the hub never saw as active.
    static var defaultPollTimeout: Duration { .seconds(30) }
    /// Default interval between fallback poll attempts.
    static var defaultPollInterval: Duration { .milliseconds(50) }

    let hub: TurnEventHub
    var pollInterval: Duration = defaultPollInterval
    var pollTimeout: Duration = defaultPollTimeout

    /// Waits for `turnID` to reach a terminal state and returns the durable value `fetch`
    /// produces once it does.
    ///
    /// - Parameter fetch: Reads the durable terminal value if one exists yet. Returning `nil`
    ///   means "not terminal yet" and keeps the fallback poll running.
    /// - Throws: `CancellationError` if the calling task is cancelled while waiting, or whatever
    ///   `fetch` throws.
    func awaitResult<Value: Sendable>(
        turnID: UUID,
        fetch: @Sendable () async throws -> Value?
    ) async throws -> Observation<Value> {
        let wait = await hub.awaitTerminal(turnID: turnID)
        try Task.checkCancellation()
        if case .observed = wait, let value = try await fetch() {
            return .value(value)
        }
        // Either the hub never tracked this Turn (`.unseen` — another process, or a Turn already
        // terminal before this call), or it fired but the durable write is not visible on this
        // read yet. The hub only signals *when* to look; the repository write always precedes
        // `finish(turnID:)`, so this settles with at most a couple of poll ticks either way.
        return try await poll(fetch: fetch)
    }

    private func poll<Value: Sendable>(
        fetch: @Sendable () async throws -> Value?
    ) async throws -> Observation<Value> {
        let deadline = ContinuousClock.now.advanced(by: pollTimeout)
        while true {
            try Task.checkCancellation()
            if let value = try await fetch() {
                return .value(value)
            }
            if ContinuousClock.now >= deadline {
                return .timedOut
            }
            try await Task.sleep(for: pollInterval)
        }
    }
}
