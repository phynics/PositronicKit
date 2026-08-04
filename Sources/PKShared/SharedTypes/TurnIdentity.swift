import Foundation

/// Stable identity for one round-trip within a logical chat send.
public struct TurnIdentity: Sendable, Hashable, Equatable, Codable {
    public let sendID: UUID
    public let roundTrip: Int

    public init(sendID: UUID, roundTrip: Int) {
        self.sendID = sendID
        self.roundTrip = roundTrip
    }

    /// Creates a turn identity using the legacy identifier spelling.
    @available(*, deprecated, message: "Use init(sendID:roundTrip:).")
    public init(sendId: UUID, roundTrip: Int) {
        self.init(sendID: sendId, roundTrip: roundTrip)
    }

    /// The send identifier using the legacy 3.x spelling.
    @available(*, deprecated, renamed: "sendID")
    public var sendId: UUID { sendID }

    private enum CodingKeys: String, CodingKey {
        case sendID = "sendId"
        case roundTrip
    }
}
