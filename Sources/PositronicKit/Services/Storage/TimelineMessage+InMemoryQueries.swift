import Foundation
import PKContracts

/// Query semantics the in-memory message stores share, so the standalone store and the cohesive
/// repository answer the same history question the same way.
extension Sequence<TimelineMessage> {
    /// The messages in timestamp order. Messages with equal timestamps keep insertion order.
    func chronological() -> [TimelineMessage] {
        enumerated()
            .sorted { lhs, rhs in
                if lhs.element.timestamp != rhs.element.timestamp {
                    return lhs.element.timestamp < rhs.element.timestamp
                }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }
}
