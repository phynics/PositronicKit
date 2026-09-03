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
    public func events() -> AsyncStream<TurnEvent> {
        eventStream
    }

    /// Waits for and returns the same durable terminal outcome seen by every joiner.
    ///
    /// - Throws: `CancellationError` if the calling task is cancelled before the Turn reaches a
    ///   terminal state, or ``TurnOutcomeTimedOut`` if the bounded wait elapses first. Neither
    ///   case is a durable outcome -- the Turn may still be running.
    public func outcome() async throws -> TurnOutcome {
        try await kit.waitForTurnOutcome(id: id)
    }

    /// Requests cancellation of exactly this Turn.
    public func cancel() async {
        await kit.cancelTurn(id: id, threadID: threadID)
    }
}
