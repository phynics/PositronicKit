import Foundation
import PKContracts

/// A stable, nonthrowing handle for one admitted Turn.
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
    public func outcome() async -> TurnOutcome {
        await kit.waitForTurnOutcome(id: id)
    }

    /// Requests cancellation of exactly this Turn.
    public func cancel() async {
        await kit.cancelTurn(id: id, threadID: threadID)
    }
}
