import Foundation
import PKContracts
import PKUtilities
import Synchronization

// MARK: - Turn handles

/// Admitting a Turn and observing it to its terminal outcome.
///
/// These members live on the engine rather than on ``PKRuntime`` because they need the engine's
/// dependencies — the repository, the event hub, the clock, the default generation parameters —
/// and none of the facade's. Keeping them here lets ``TimelineHandle`` and ``TurnHandle`` hold a
/// `TurnEngine` instead of the whole runtime.
extension TurnEngine {

    func startTurnHandle(
        _ request: TurnRequest,
        agentID: UUID?,
        executionKind: TurnExecutionKind,
        contributors: [TurnContributor] = []
    ) async throws -> TurnHandle {
        let executionRequest = TurnExecutionRequest(
            request,
            defaultGenerationParameters: dependencies.policy.generationParameters,
            agentID: agentID,
            executionKind: executionKind,
            contributors: contributors
        )
        let execution = try await startExecution(executionRequest)
        return TurnHandle(
            id: execution.turnID,
            timelineID: request.timelineID,
            eventStream: nonThrowingEvents(
                from: execution.stream,
                // Consumer cancellation must reach the Turn on the public path too, not only on
                // the engine-test `TurnEngine.execute(_:)` path.
                relay: consumerCancellationRelay(for: execution, timelineID: request.timelineID)
            ),
            engine: self
        )
    }

    /// Bridges the Turn's throwing event stream onto the nonthrowing stream a `TurnHandle`
    /// hands out, and relays consumer abandonment back to the Turn.
    ///
    /// This is the only hop between the Turn and its public consumer: the relay rides on this
    /// bridge rather than wrapping `source` in a second stream, so an abandoned consumer is
    /// observed without adding a task to every Turn.
    private func nonThrowingEvents(
        from source: AsyncThrowingStream<TurnEvent, Error>,
        relay: TurnEngine.ConsumerCancellationRelay
    ) -> AsyncStream<TurnEvent> {
        AsyncStream { continuation in
            let reachedTerminalState = Mutex(false)
            let bridge = Task {
                var terminalDelivered = false
                do {
                    for try await event in source {
                        if event.isTerminal {
                            if terminalDelivered { continue }
                            terminalDelivered = true
                            // Set before the yield below: a consumer must not be able to observe
                            // the terminal event and break while the relay still thinks the Turn
                            // is live.
                            reachedTerminalState.withLock { $0 = true }
                        }
                        continuation.yield(event)
                    }
                } catch {
                    if !terminalDelivered {
                        continuation.yield(.error(error))
                    }
                }
                reachedTerminalState.withLock { $0 = true }
                continuation.finish()
            }
            continuation.onTermination = { @Sendable termination in
                // Without this the bridge outlives an abandoned consumer and keeps draining
                // `source` for events nobody will read.
                bridge.cancel()
                guard case .cancelled = termination else { return }
                relay.consumerAbandoned(reachedTerminalState: reachedTerminalState.withLock { $0 })
            }
        }
    }

    func waitForTurnOutcome(id turnID: UUID) async throws -> TurnOutcome {
        let waiter = TurnTerminationWaiter(
            hub: dependencies.eventHub,
            clock: dependencies.policy.clock
        )
        let observation = try await waiter.awaitResult(turnID: turnID) {
            try await dependencies.runtimeRepository.fetchTurn(id: turnID)?.outcome
        }
        switch observation {
        case let .value(outcome):
            return outcome
        case .timedOut:
            throw TurnOutcomeTimedOut(turnID: turnID)
        }
    }

    /// Waits for the Turn's terminal record, then resolves its consolidated result.
    ///
    /// Uses the same push-then-bounded-poll waiter as ``waitForTurnOutcome(id:)``,
    /// but fetches the full terminal `TurnRecord` and resolves
    /// `terminalMessageID` through the runtime repository's durable messages.
    /// A missing terminal message row yields `message == nil`; the outcome
    /// remains authoritative either way. Observation sinks and the prompt
    /// journal are never consulted.
    func waitForTurnResult(id turnID: UUID) async throws -> TurnResult {
        let waiter = TurnTerminationWaiter(
            hub: dependencies.eventHub,
            clock: dependencies.policy.clock
        )
        let observation = try await waiter.awaitResult(turnID: turnID) {
            let record = try await dependencies.runtimeRepository.fetchTurn(id: turnID)
            return record.flatMap { $0.isTerminal ? $0 : nil }
        }
        switch observation {
        case let .value(record):
            guard let outcome = record.outcome else {
                throw TurnOutcomeTimedOut(turnID: turnID)
            }
            let message: Message?
            if let messageID = record.terminalMessageID {
                let messages = try await dependencies.runtimeRepository.fetchMessages(for: record.timelineID)
                message = messages.first(where: { $0.id == messageID })?.toMessage()
            } else {
                message = nil
            }
            return TurnResult(
                turnID: turnID,
                timelineID: record.timelineID,
                outcome: outcome,
                message: message
            )
        case .timedOut:
            throw TurnOutcomeTimedOut(turnID: turnID)
        }
    }

    /// Runs the package-internal engine request and returns its throwing event stream.
    ///
    /// This is reserved for runtime-owned engine tests. Public callers admit Turns through a
    /// ``TimelineHandle`` and receive a ``TurnHandle`` instead.
    ///
    /// - Parameter request: The package-internal turn configuration.
    /// - Returns: An asynchronous stream of turn events.
    func run(
        _ request: TurnRequest,
        agentID: UUID? = nil,
        executionKind: TurnExecutionKind = .direct,
        contributors: [TurnContributor] = []
    ) async throws -> AsyncThrowingStream<TurnEvent, Error> {
        let executionRequest = TurnExecutionRequest(
            request,
            defaultGenerationParameters: dependencies.policy.generationParameters,
            agentID: agentID,
            executionKind: executionKind,
            contributors: contributors
        )
        return try await execute(executionRequest)
    }
}
