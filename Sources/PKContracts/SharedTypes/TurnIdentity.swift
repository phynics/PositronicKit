import Foundation

/// Stable identity for one model round within an admitted turn.
public struct TurnIdentity: Sendable, Hashable, Equatable, Codable {
    /// Runtime identity of the admitted execution.
    public let turnID: UUID
    /// Caller-owned idempotency identity for the request that admitted the turn.
    public let requestID: UUID
    /// Zero-based model interaction index within the turn.
    public let modelRoundIndex: Int

    public init(turnID: UUID, requestID: UUID, modelRoundIndex: Int) {
        self.turnID = turnID
        self.requestID = requestID
        self.modelRoundIndex = modelRoundIndex
    }

    private enum CodingKeys: String, CodingKey {
        case turnID = "turnId"
        case requestID = "requestId"
        case modelRoundIndex
    }
}
