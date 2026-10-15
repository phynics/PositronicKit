import Foundation

/// Lineage recorded on an ephemeral Timeline that was forked from another Timeline.
///
/// A fork copies the source Timeline's semantic message history into a new detached, private,
/// ephemeral Timeline in the same runtime. The origin records which Timeline it came from, the
/// last source message copied (the fork point), and when the fork was taken. The type is
/// principal-neutral: it names no Agent or other execution authority, so a future opaque
/// principal can own Timeline lineage without a shape change.
public struct TimelineForkOrigin: Codable, Equatable, Hashable, Sendable {
    /// The Timeline the fork copied its history from.
    public let timelineID: UUID

    /// The source message that was the last one copied into the fork, or `nil` when the source
    /// had no messages at fork time.
    public let throughMessageID: UUID?

    /// When the fork was taken.
    public let at: Date

    public init(timelineID: UUID, throughMessageID: UUID?, at: Date) {
        self.timelineID = timelineID
        self.throughMessageID = throughMessageID
        self.at = at
    }
}
