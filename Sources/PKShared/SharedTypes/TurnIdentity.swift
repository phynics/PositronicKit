import Foundation

/// Stable identity for one round-trip within a logical chat send.
public struct TurnIdentity: Sendable, Hashable, Equatable, Codable {
    public let sendID: UUID
    public let roundTrip: Int

    public init(sendID: UUID, roundTrip: Int) {
        self.sendID = sendID
        self.roundTrip = roundTrip
    }

    private enum CodingKeys: String, CodingKey {
        case sendID = "sendId"
        case roundTrip
    }
}
