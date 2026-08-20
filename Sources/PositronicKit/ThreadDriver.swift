import Foundation
import PKContracts

/// A lightweight, stable handle for sending to and cancelling work on exactly one durable
/// ``Thread``.
///
/// `ThreadDriver` holds no mutable turn state, does not perform persistence lookups on
/// construction, and does not expose the underlying `ThreadManager`. Opening a driver via
/// `PositronicKit.openThread(_:)` is pure value construction — persistence happens lazily,
/// the first time `send(_:)` actually executes a turn, exactly as it always has for the
/// underlying chat-engine turn path.
public struct ThreadDriver: Identifiable, Sendable {
    /// The persisted thread this driver sends to and cancels work for.
    public let threadID: UUID

    /// Stable identity; equal to `threadID`.
    public var id: UUID {
        threadID
    }

    private let kit: PositronicKit

    init(threadID: UUID, kit: PositronicKit) {
        self.threadID = threadID
        self.kit = kit
    }

    /// Sends a message through the facade's normal chat-engine execution path.
    public func send(_ message: String) async throws -> AsyncThrowingStream<TurnEvent, Error> {
        try await kit.run(TurnRequest(threadID: threadID, message: message))
    }

    /// Cancels any in-flight generation for this driver's thread.
    public func cancel() async {
        await kit.threadManager.cancelGeneration(for: threadID)
    }
}

public extension PositronicKit {
    /// Opens an **existing** thread for sending and cancellation.
    ///
    /// This is pure driver construction: it performs no persistence I/O. The thread
    /// must have been created beforehand via ``ThreadManager/createThread(title:)``.
    /// A missing (never-persisted) thread id is an error, not a silent creation —
    /// the first ``ThreadDriver/send(_:)`` call will throw
    /// ``ThreadError/threadNotFound`` before any message is persisted.
    func openThread(_ threadID: UUID) -> ThreadDriver {
        ThreadDriver(threadID: threadID, kit: self)
    }

}
