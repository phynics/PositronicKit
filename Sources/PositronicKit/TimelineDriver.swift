import Foundation
import PKShared

/// A lightweight, stable handle for sending to and cancelling work on exactly one durable
/// ``Timeline``.
///
/// `TimelineDriver` holds no mutable turn state, does not perform persistence lookups on
/// construction, and does not expose the underlying `TimelineManager`. Opening a driver via
/// `PositronicKit.openTimeline(_:)` is pure value construction — persistence happens lazily,
/// the first time `send(_:)` actually executes a turn, exactly as it always has for the
/// underlying chat-engine turn path.
public struct TimelineDriver: Identifiable, Sendable {
    /// The persisted timeline this driver sends to and cancels work for.
    public let timelineID: UUID

    /// Stable identity; equal to `timelineID`.
    public var id: UUID {
        timelineID
    }

    private let kit: PositronicKit

    init(timelineID: UUID, kit: PositronicKit) {
        self.timelineID = timelineID
        self.kit = kit
    }

    /// Sends a message through the facade's normal chat-engine execution path.
    public func send(_ message: String) async throws -> AsyncThrowingStream<ChatEvent, Error> {
        try await kit.run(ChatRunRequest(timelineId: timelineID, message: message))
    }

    /// Cancels any in-flight generation for this driver's timeline.
    public func cancel() async {
        await kit.timelineManager.cancelGeneration(for: timelineID)
    }
}

public extension PositronicKit {
    /// Constructs a driver for an existing or future timeline id.
    ///
    /// This is pure driver construction: it performs no persistence I/O. A brand-new
    /// (never-persisted) timeline id is valid here — the first `send(_:)` call is what
    /// hydrates or creates the backing `Timeline` record, just as it always has.
    func openTimeline(_ timelineID: UUID) -> TimelineDriver {
        TimelineDriver(timelineID: timelineID, kit: self)
    }
}
