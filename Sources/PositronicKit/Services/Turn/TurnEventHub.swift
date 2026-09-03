import Foundation
import PKContracts

/// Process-local multicast for live Turn events.
///
/// Incremental events are intentionally not durable. A joiner that subscribes while a Turn is
/// active receives future events; terminal outcome replay is served from the runtime repository.
actor TurnEventHub {
    /// The result of ``awaitTerminal(turnID:)``.
    enum TerminalWait: Sendable, Equatable {
        /// The hub observed `turnID` reach a terminal state and woke the waiter directly.
        case observed
        /// The hub never tracked `turnID` as active (admitted by another process, or already
        /// terminal before the caller asked). The caller must fall back to a durable read.
        case unseen
    }

    private struct Subscriber {
        let continuation: AsyncThrowingStream<TurnEvent, Error>.Continuation // swiftlint:disable:this concurrency_stored_continuation -- actor-owned subscriber lifecycle (see docs/Concurrency/exception-manifest.md)
    }

    private var subscribers: [UUID: [UUID: Subscriber]] = [:]
    private var activeTurns: Set<UUID> = []
    private var terminalWaiters: [UUID: [UUID: CheckedContinuation<Void, Never>]] = [:] // swiftlint:disable:this concurrency_stored_continuation -- actor-owned terminal-wait lifecycle (see docs/Concurrency/exception-manifest.md)

    func begin(turnID: UUID) {
        activeTurns.insert(turnID)
    }

    func subscribe(turnID: UUID) -> AsyncThrowingStream<TurnEvent, Error> {
        makeSubscription(turnID: turnID)
    }

    /// Selects the live lane and registers its subscriber in one actor operation. A caller that
    /// gets `nil` must use durable replay; there is no check/subscribe gap in which a finished lane
    /// can leave the returned stream waiting forever.
    func subscribeIfActive(turnID: UUID) -> AsyncThrowingStream<TurnEvent, Error>? {
        guard activeTurns.contains(turnID) else { return nil }
        return makeSubscription(turnID: turnID)
    }

    private func makeSubscription(turnID: UUID) -> AsyncThrowingStream<TurnEvent, Error> {
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
        let waiters = terminalWaiters.removeValue(forKey: turnID) ?? [:]
        for continuation in waiters.values {
            continuation.resume()
        }
    }

    /// Suspends until `turnID` reaches a terminal state as observed by this hub.
    ///
    /// If the hub is tracking `turnID` as active, this registers a waiter and the actor-isolated
    /// registration happens fully before the call can suspend, so a concurrent `finish(turnID:)`
    /// can never miss it and a concurrent cancellation can never remove a waiter that was never
    /// added — both operations serialize through this actor. If the hub is not tracking `turnID`
    /// as active — never admitted here, or already finished — this returns `.unseen` immediately;
    /// the durable repository remains the source of truth for what actually happened, this hub
    /// only tells a caller when to look.
    func awaitTerminal(turnID: UUID) async -> TerminalWait {
        guard activeTurns.contains(turnID) else { return .unseen }
        let waiterID = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                guard activeTurns.contains(turnID) else {
                    continuation.resume()
                    return
                }
                terminalWaiters[turnID, default: [:]][waiterID] = continuation
            }
        } onCancel: {
            Task { await self.cancelTerminalWait(turnID: turnID, waiterID: waiterID) }
        }
        return .observed
    }

    private func cancelTerminalWait(turnID: UUID, waiterID: UUID) {
        guard let continuation = terminalWaiters[turnID]?.removeValue(forKey: waiterID) else { return }
        if terminalWaiters[turnID]?.isEmpty == true {
            terminalWaiters.removeValue(forKey: turnID)
        }
        continuation.resume()
    }

    private func remove(_ subscriberID: UUID, from turnID: UUID) {
        subscribers[turnID]?.removeValue(forKey: subscriberID)
        if subscribers[turnID]?.isEmpty == true {
            subscribers.removeValue(forKey: turnID)
        }
    }
}
