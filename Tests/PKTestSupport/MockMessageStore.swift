import Foundation
import PKContracts
import PKUtilities
import PositronicKit
import Synchronization

/// In-memory `TimelineMessageStoreProtocol` test double backed by a mutex-guarded array.
///
/// Inspectable: `messages` reads/writes the backing store directly, so tests can seed
/// fixtures or assert on saved state.
public final class MockMessageStore: TimelineMessageStoreProtocol, @unchecked Sendable { // swiftlint:disable:this concurrency_unchecked_sendable -- reviewed test double (see docs/Concurrency/exception-manifest.md)
    private let messagesState = Mutex<[TimelineMessage]>([])

    public var messages: [TimelineMessage] {
        get { messagesState.withLock { $0 } }
        set { messagesState.withLock { $0 = newValue } }
    }

    public init() {}

    public func saveMessage(_ message: TimelineMessage) async throws {
        messagesState.withLock {
            if $0.contains(where: { $0.id == message.id }) {
                // The cohesive runtime repository owns the append-only error. This focused
                // double still refuses a conflicting replacement so composite conformance
                // tests cannot hide a duplicate terminal message.
                return
            }
            $0.append(message)
        }
    }

    public func fetchMessages(for timelineID: UUID) async throws -> [TimelineMessage] {
        messagesState.withLock {
            $0
                .filter { $0.timelineID == timelineID }
                .enumerated()
                .sorted { lhs, rhs in
                    if lhs.element.timestamp != rhs.element.timestamp {
                        return lhs.element.timestamp < rhs.element.timestamp
                    }
                    return lhs.offset < rhs.offset
                }
                .map { $0.element }
        }
    }
}
