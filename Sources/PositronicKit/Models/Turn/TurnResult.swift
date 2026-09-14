import Foundation
import PKContracts

/// The consolidated, durable result of one admitted Turn.
///
/// `TurnResult` is the common-path companion to the full-fidelity `TurnEvent`
/// stream: instead of exhaustively switching over nested event cases plus
/// separate outcome and history lookups, callers await `TurnHandle/result()`
/// once and read this value.
///
/// The terminal state always comes from the atomic Timeline runtime repository,
/// so every joiner observes the same durable result. `message` is the final
/// assistant message when the Turn durably recorded one — including an empty
/// assistant row for empty output — and `nil` when no terminal row exists
/// (deferred external tools, or failure/cancellation before any content was
/// durable). Distinguish those cases via `outcome`, not via message presence.
public struct TurnResult: Sendable, Equatable {
    /// The admitted Turn this result belongs to.
    public let turnID: UUID
    /// The Timeline the Turn ran on.
    public let timelineID: UUID
    /// The durable terminal outcome recorded by the runtime repository.
    public let outcome: TurnOutcome
    /// The final assistant message, when the Turn durably produced one.
    public let message: Message?

    public init(turnID: UUID, timelineID: UUID, outcome: TurnOutcome, message: Message? = nil) {
        self.turnID = turnID
        self.timelineID = timelineID
        self.outcome = outcome
        self.message = message
    }
}
