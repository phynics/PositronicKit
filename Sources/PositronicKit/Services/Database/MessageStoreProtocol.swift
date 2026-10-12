import PKContracts
import PKUtilities

// Protocol for managing chat history and message persistence.

import Foundation

public protocol TimelineMessageStoreProtocol: DurabilityAware {
    func saveMessage(_ message: TimelineMessage) async throws

    /// Fetches the durable messages for a Timeline in transcript order.
    ///
    /// Results must be ordered by ascending ``TimelineMessage/timestamp``. Messages with equal
    /// timestamps must retain their append order. An unknown Timeline ID returns an empty array.
    func fetchMessages(for timelineID: UUID) async throws -> [TimelineMessage]
}
