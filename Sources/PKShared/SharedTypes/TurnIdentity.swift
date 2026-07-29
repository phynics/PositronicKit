import Foundation

/// Stable identity for one round-trip within a logical chat send.
public struct TurnIdentity: Sendable, Hashable, Equatable, Codable {
    public let sendId: UUID
    public let roundTrip: Int

    public init(sendId: UUID, roundTrip: Int) {
        self.sendId = sendId
        self.roundTrip = roundTrip
    }
}
