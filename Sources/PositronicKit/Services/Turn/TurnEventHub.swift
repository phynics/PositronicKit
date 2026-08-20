import Foundation
import PKContracts

/// Process-local multicast for live Turn events.
///
/// Incremental events are intentionally not durable. A joiner that subscribes while a Turn is
/// active receives future events; terminal outcome replay is served from the runtime repository.
actor TurnEventHub {
    private struct Subscriber {
        let continuation: AsyncThrowingStream<TurnEvent, Error>.Continuation
    }

    private var subscribers: [UUID: [UUID: Subscriber]] = [:]
    private var activeTurns: Set<UUID> = []

    func begin(turnID: UUID) {
        activeTurns.insert(turnID)
    }

    func isActive(turnID: UUID) -> Bool {
        activeTurns.contains(turnID)
    }

    func subscribe(turnID: UUID) -> AsyncThrowingStream<TurnEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream<TurnEvent, Error>.makeStream()
        let subscriberID = UUID()
        subscribers[turnID, default: [:]][subscriberID] = Subscriber(continuation: continuation)
        continuation.onTermination = { @Sendable [weak self] _ in
            Task { await self?.remove(subscriberID, from: turnID) }
        }
        return stream
    }

    func publish(_ event: TurnEvent, turnID: UUID) {
        for subscriber in subscribers[turnID, default: [:]].values {
            subscriber.continuation.yield(event)
        }
    }

    func finish(turnID: UUID, error: Error? = nil) {
        let current = subscribers.removeValue(forKey: turnID) ?? [:]
        activeTurns.remove(turnID)
        for subscriber in current.values {
            if let error {
                subscriber.continuation.finish(throwing: error)
            } else {
                subscriber.continuation.finish()
            }
        }
    }

    private func remove(_ subscriberID: UUID, from turnID: UUID) {
        subscribers[turnID]?.removeValue(forKey: subscriberID)
        if subscribers[turnID]?.isEmpty == true {
            subscribers.removeValue(forKey: turnID)
        }
    }
}
