import Foundation
import PKContracts

/// Thrown by ``TurnHandle/outcome()`` when the bounded wait for a Turn's durable outcome elapses
/// before one was observed.
///
/// This is deliberately not a `TurnOutcome` case: the Turn was never confirmed to reach a
/// terminal state, durable or otherwise. It may still be running.
public struct TurnOutcomeTimedOut: Error, Sendable {
    /// The Turn whose outcome was not observed in time.
    public let turnID: UUID

    public init(turnID: UUID) {
        self.turnID = turnID
    }
}

/// A stable handle for one admitted Turn.
///
/// The event stream carries future events only. Terminal state is read from the durable runtime
/// repository by outcome() and can therefore be replayed after the live stream has ended.
public struct TurnHandle: Identifiable, Sendable {
    public let id: UUID
    public let threadID: UUID

    private let eventStream: AsyncStream<TurnEvent>
    private let kit: PositronicKit

    init(id: UUID, threadID: UUID, eventStream: AsyncStream<TurnEvent>, kit: PositronicKit) {
        self.id = id
        self.threadID = threadID
        self.eventStream = eventStream
        self.kit = kit
    }

    /// Returns the nonthrowing future-event stream for this Turn.
    ///
    /// `events()` and `generatedText()` are alternative views over one shared
    /// underlying stream: consume the Turn through one of them, not both
    /// concurrently. Iterating both at once splits events between the two
    /// iterators. `outcome()` and `result()` never consume the stream, so any
    /// number of joiners can await them alongside — or after — either view.
    public func events() -> AsyncStream<TurnEvent> {
        eventStream
    }

    /// Streams the Turn's generated assistant text in emission order.
    ///
    /// This is a projection over `events()`: only `.delta(.generation)` text
    /// fragments are yielded, in the order they arrive. Reasoning, tool-call,
    /// audio, and sidecar deltas are skipped, and terminal completion and error
    /// events terminate the sequence without yielding text. It creates no
    /// second execution or persistence path — it observes the same underlying
    /// event stream, so generated text is neither lost nor duplicated relative
    /// to `events()`.
    ///
    /// Abandoning the sequence (for example via `break`) follows the same rule
    /// as abandoning `events()`: only the caller that admitted the Turn can
    /// cancel its generation, and abandonment after the terminal event never
    /// cancels anything. A joiner observing another caller's Turn can abandon
    /// freely while the owner's generation keeps running.
    ///
    /// `generatedText()` shares its underlying stream with `events()`: use one
    /// of them as the Turn's stream consumer, not both concurrently.
    public func generatedText() -> AsyncStream<String> {
        AsyncStream { continuation in
            let consumption = Task {
                for await event in eventStream {
                    if let text = event.textContent {
                        continuation.yield(text)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in
                consumption.cancel()
            }
        }
    }

    /// Waits for and returns the same durable terminal outcome seen by every joiner.
    ///
    /// - Throws: `CancellationError` if the calling task is cancelled before the Turn reaches a
    ///   terminal state, or ``TurnOutcomeTimedOut`` if the bounded wait elapses first. Neither
    ///   case is a durable outcome -- the Turn may still be running.
    public func outcome() async throws -> TurnOutcome {
        try await kit.waitForTurnOutcome(id: id)
    }

    /// Waits for and returns the same durable consolidated result seen by every joiner.
    ///
    /// The outcome and final assistant message are read from the atomic Thread
    /// runtime repository after the Turn reaches a terminal state — never
    /// synthesized from observed events — so this returns the same `TurnResult`
    /// for every caller, including callers that never consumed `events()` or
    /// `generatedText()`. The full event stream remains available for advanced
    /// consumers.
    ///
    /// - Throws: `CancellationError` if the calling task is cancelled before the Turn reaches a
    ///   terminal state, or ``TurnOutcomeTimedOut`` if the bounded wait elapses first. Neither
    ///   case is a durable outcome -- the Turn may still be running.
    public func result() async throws -> TurnResult {
        try await kit.waitForTurnResult(id: id)
    }

    /// Requests cancellation of exactly this Turn.
    public func cancel() async {
        await kit.cancelTurn(id: id, threadID: threadID)
    }
}
