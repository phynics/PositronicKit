import Foundation
import PKShared

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

    /// Deprecated v3 initializer retained for in-module source compatibility.
    @available(*, deprecated, message: "Timeline APIs are deprecated and will be removed in v4. Use the corresponding Thread API instead.")
    init(timelineID: UUID, kit: PositronicKit) {
        self.init(threadID: timelineID, kit: kit)
    }

    /// Deprecated v3 spelling for the thread identifier.
    @available(*, deprecated, renamed: "threadID", message: "Timeline APIs are deprecated and will be removed in v4. Use the corresponding Thread API instead.")
    public var timelineID: UUID { threadID }

    /// Deprecated lower-camel v3 spelling for the thread identifier.
    @available(*, deprecated, renamed: "threadID", message: "Timeline APIs are deprecated and will be removed in v4. Use the corresponding Thread API instead.")
    public var timelineId: UUID { threadID }

    /// Sends a message through the facade's normal chat-engine execution path.
    public func send(_ message: String) async throws -> AsyncThrowingStream<ChatEvent, Error> {
        try await kit.run(ChatRunRequest(threadID: threadID, message: message))
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

    /// Deprecated v3 spelling for ``openThread(_:)``.
    @available(*, deprecated, renamed: "openThread(_:)", message: "Timeline APIs are deprecated and will be removed in v4. Use the corresponding Thread API instead.")
    func openTimeline(_ timelineID: UUID) -> ThreadDriver {
        openThread(timelineID)
    }
}
