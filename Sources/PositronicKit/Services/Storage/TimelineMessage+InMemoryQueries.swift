import Foundation
import PKContracts

/// Query semantics the in-memory message stores share, so the standalone store and the cohesive
/// repository answer the same history questions the same way.
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

    /// The Turn snapshots attached to assistant messages. Undecodable snapshots are skipped.
    func assistantSnapshots() -> [TurnSnapshot] {
        filter { $0.role == "assistant" }
            .compactMap { message in
                guard let data = message.snapshotData else { return nil }
                return try? SerializationUtils.jsonDecoder.decode(TurnSnapshot.self, from: data)
            }
    }
}
