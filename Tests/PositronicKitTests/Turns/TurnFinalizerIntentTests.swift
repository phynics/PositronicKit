import Foundation
import PKContracts
import PKTestSupport
import PKUtilities
@testable import PositronicKit
import Testing

/// The finalizer is the single module that resolves a Turn's final assistant row. These tests drive
/// `TurnFinalizer.submit` directly with a fake repository, so the completed / cancelled / failed /
/// interrupted matrix is asserted without a live provider or Timeline (issue #305).
@Suite("Turn finalizer terminal intent", .tags(.integration))
struct TurnFinalizerIntentTests {
    private let timelineID = UUID()

    private func makeFinalizer(_ repository: MockPersistenceService) -> TurnFinalizer {
        TurnFinalizer(
            repository: repository,
            agentActivitySink: nil,
            turnOutcomeSink: nil,
            clock: ContinuousRuntimeClock()
        )
    }

    private func admitTurn(_ repository: MockPersistenceService, requestID: UUID) async throws -> UUID {
        if try await repository.fetchTimeline(id: timelineID) == nil {
            try await repository.saveTimeline(TimelineRecord(id: timelineID, title: "Finalizer intent"))
        }
        let admission = try await repository.admitTurn(
            timelineID: timelineID,
            requestID: requestID,
            callerIntentFingerprint: "intent-test"
        )
        return admission.turn.identity.turnID
    }

    private func makeCommit(
        turnID: UUID,
        requestID: UUID,
        outcome: TurnOutcome,
        finalMessage: TerminalCommit.FinalMessage,
        delivery: TerminalCommit.Delivery,
        streamFailure: Error? = nil,
        continuation: AsyncThrowingStream<TurnEvent, Error>.Continuation
    ) -> TerminalCommit {
        TerminalCommit(
            turnID: turnID,
            timelineID: timelineID,
            requestID: requestID,
            outcome: outcome,
            finalMessage: finalMessage,
            delivery: delivery,
            terminalHandle: TurnTerminalHandle(turnID: turnID),
            metadata: nil,
            sidecarCompletion: nil,
            agentID: nil,
            executionKind: .direct,
            modelRoundIndex: 1,
            streamFailure: streamFailure.map(TerminalStreamFailure.init(error:)),
            continuation: continuation
        )
    }

    /// Submits one commit, joins it, and returns the events the consumer observed.
    private func run(
        _ finalizer: TurnFinalizer,
        turnID: UUID,
        requestID: UUID,
        outcome: TurnOutcome,
        finalMessage: TerminalCommit.FinalMessage,
        delivery: TerminalCommit.Delivery
    ) async throws -> [TurnEvent] {
        let (stream, continuation) = AsyncThrowingStream<TurnEvent, Error>.makeStream()
        let collector = Task { () -> [TurnEvent] in
            var events: [TurnEvent] = []
            for try await event in stream { events.append(event) }
            return events
        }
        await finalizer.submit(makeCommit(
            turnID: turnID,
            requestID: requestID,
            outcome: outcome,
            finalMessage: finalMessage,
            delivery: delivery,
            continuation: continuation
        ))
        await finalizer.awaitPendingCommits(forTimeline: timelineID)
        return try await collector.value
    }

    private func partialMaterial(content: String) -> AssistantRowMaterial {
        AssistantRowMaterial(
            timelineID: timelineID,
            agentID: nil,
            executionKind: .direct,
            content: MessageContent(content),
            thinking: "",
            toolCallsJSON: "[]"
        )
    }

    // MARK: - Durability matrix

    @Test("a completed Turn commits the captured terminal row and emits generationCompleted")
    func completedCommitsCapturedTerminal() async throws {
        let repository = MockPersistenceService()
        let finalizer = makeFinalizer(repository)
        let requestID = UUID()
        let turnID = try await admitTurn(repository, requestID: requestID)
        let terminal = TimelineMessage(timelineID: timelineID, role: .assistant, content: "final")

        let events = try await run(
            finalizer,
            turnID: turnID,
            requestID: requestID,
            outcome: .completed,
            finalMessage: .terminalAssistantMessage(terminal),
            delivery: .completion
        )

        #expect(try await repository.fetchTurn(id: turnID)?.outcome == .completed)
        #expect(repository.messages.contains { $0.id == terminal.id })
        #expect(events.contains { if case .completion(.generationCompleted) = $0 { return true }; return false })
    }

    @Test("a completed Turn with no captured row falls back to the last durable assistant row")
    func completedFallsBackToDurableHistory() async throws {
        let repository = MockPersistenceService()
        let finalizer = makeFinalizer(repository)
        let requestID = UUID()
        let turnID = try await admitTurn(repository, requestID: requestID)
        let user = TimelineMessage(id: requestID, timelineID: timelineID, role: .user, content: "hi")
        let durable = TimelineMessage(timelineID: timelineID, role: .assistant, content: "durable reply")
        try await repository.recordTurnMessage(user, turnID: turnID)
        try await repository.recordTurnMessage(durable, turnID: turnID)

        let events = try await run(
            finalizer,
            turnID: turnID,
            requestID: requestID,
            outcome: .completed,
            finalMessage: .lastDurableAssistantMessage,
            delivery: .completion
        )

        #expect(repository.messages.contains { $0.id == durable.id })
        // Without a captured terminal row the delivery stays empty, matching the prior behavior.
        #expect(events.contains { if case .completion(.completedEmpty) = $0 { return true }; return false })
    }

    @Test("a cancelled Turn commits a partial row tagged cancelled")
    func cancelledCommitsCancelledPartial() async throws {
        let repository = MockPersistenceService()
        let finalizer = makeFinalizer(repository)
        let requestID = UUID()
        let turnID = try await admitTurn(repository, requestID: requestID)
        let source = PartialAssistantSource(
            responseIsDurable: false,
            terminalMessage: nil,
            material: partialMaterial(content: "half")
        )

        let events = try await run(
            finalizer,
            turnID: turnID,
            requestID: requestID,
            outcome: .cancelled(reason: "stop"),
            finalMessage: .partialAssistant(source),
            delivery: .event(.generationCancelled())
        )

        let row = repository.messages.first { $0.content == "half" }
        #expect(row?.status == .cancelled)
        #expect(try await repository.fetchTurn(id: turnID)?.outcome == .cancelled(reason: "stop"))
        #expect(events.contains { if case .error(.generationCancelled) = $0 { return true }; return false })
    }

    @Test("a failed Turn commits a partial row tagged partial")
    func failedCommitsPartialStatus() async throws {
        let repository = MockPersistenceService()
        let finalizer = makeFinalizer(repository)
        let requestID = UUID()
        let turnID = try await admitTurn(repository, requestID: requestID)
        let source = PartialAssistantSource(
            responseIsDurable: false,
            terminalMessage: nil,
            material: partialMaterial(content: "broke")
        )

        _ = try await run(
            finalizer,
            turnID: turnID,
            requestID: requestID,
            outcome: .failed(message: "provider error"),
            finalMessage: .partialAssistant(source),
            delivery: .none
        )

        let row = repository.messages.first { $0.content == "broke" }
        #expect(row?.status == .partial)
        #expect(try await repository.fetchTurn(id: turnID)?.outcome == .failed(message: "provider error"))
    }

    @Test("a cancelled Turn whose response is already durable attaches no partial row")
    func cancelledWithDurableResponseAttachesNothing() async throws {
        let repository = MockPersistenceService()
        let finalizer = makeFinalizer(repository)
        let requestID = UUID()
        let turnID = try await admitTurn(repository, requestID: requestID)
        let source = PartialAssistantSource(
            responseIsDurable: true,
            terminalMessage: nil,
            material: partialMaterial(content: "ignored")
        )

        _ = try await run(
            finalizer,
            turnID: turnID,
            requestID: requestID,
            outcome: .cancelled(reason: "stop"),
            finalMessage: .partialAssistant(source),
            delivery: .event(.generationCancelled())
        )

        #expect(repository.messages.isEmpty)
    }

    @Test("a failed Turn that emitted nothing attaches no partial row")
    func failedWithNothingToRecordAttachesNothing() async throws {
        let repository = MockPersistenceService()
        let finalizer = makeFinalizer(repository)
        let requestID = UUID()
        let turnID = try await admitTurn(repository, requestID: requestID)
        let source = PartialAssistantSource(
            responseIsDurable: false,
            terminalMessage: nil,
            material: nil
        )

        _ = try await run(
            finalizer,
            turnID: turnID,
            requestID: requestID,
            outcome: .failed(message: "provider error"),
            finalMessage: .partialAssistant(source),
            delivery: .none
        )

        #expect(repository.messages.isEmpty)
    }

    @Test("an interrupted Turn records no final message")
    func interruptedAttachesNothing() async throws {
        let repository = MockPersistenceService()
        let finalizer = makeFinalizer(repository)
        let requestID = UUID()
        let turnID = try await admitTurn(repository, requestID: requestID)

        let events = try await run(
            finalizer,
            turnID: turnID,
            requestID: requestID,
            outcome: .interrupted(reason: "deferred"),
            finalMessage: .none,
            delivery: .event(.deferredForExternalTool())
        )

        #expect(try await repository.fetchTurn(id: turnID)?.outcome == .interrupted(reason: "deferred"))
        #expect(repository.messages.isEmpty)
        #expect(events.contains { if case .completion(.deferredForExternalTool) = $0 { return true }; return false })
    }

    // MARK: - Ordering (ADR 0010)

    @Test("commits for one Timeline may overlap, and a late commit keeps first-writer-wins")
    func lateCommitDoesNotOverwriteInterruptedPredecessor() async throws {
        let repository = MockPersistenceService()
        let gate = FirstCommitGate()
        repository.completeTurnBlocker = { await gate.block() }
        let finalizer = makeFinalizer(repository)

        let requestA = UUID()
        let turnA = try await admitTurn(repository, requestID: requestA) // first commit parks here
        // Admission interrupted A after its commit stalled past the stall limit.
        _ = try await repository.interruptTurn(
            turnID: turnA,
            reason: "Terminal commit exceeded terminalCommitStallLimit.",
            disposition: .retryable,
            now: Date()
        )

        let (streamA, continuationA) = AsyncThrowingStream<TurnEvent, Error>.makeStream()
        let collectorA = Task { () -> [TurnEvent] in
            var events: [TurnEvent] = []
            for try await event in streamA { events.append(event) }
            return events
        }
        await finalizer.submit(makeCommit(
            turnID: turnA,
            requestID: requestA,
            outcome: .completed,
            finalMessage: .terminalAssistantMessage(
                TimelineMessage(timelineID: timelineID, role: .assistant, content: "late")
            ),
            delivery: .completion,
            continuation: continuationA
        ))
        #expect(await gate.waitUntilEntered(), "A's commit should be parked")

        // B is admitted on the same Timeline while A's commit is still in flight, and its commit
        // must complete without waiting for A.
        let requestB = UUID()
        let turnB = try await admitTurn(repository, requestID: requestB)
        let (streamB, continuationB) = AsyncThrowingStream<TurnEvent, Error>.makeStream()
        let collectorB = Task { () -> [TurnEvent] in
            var events: [TurnEvent] = []
            for try await event in streamB { events.append(event) }
            return events
        }
        await finalizer.submit(makeCommit(
            turnID: turnB,
            requestID: requestB,
            outcome: .completed,
            finalMessage: .terminalAssistantMessage(
                TimelineMessage(timelineID: timelineID, role: .assistant, content: "B")
            ),
            delivery: .completion,
            continuation: continuationB
        ))
        var bOutcome: TurnOutcome?
        for _ in 0..<100_000 {
            bOutcome = try await repository.fetchTurn(id: turnB)?.outcome
            if bOutcome == .completed { break }
            await Task.yield()
        }
        #expect(bOutcome == .completed, "B must commit while A's commit is still parked")
        #expect(try await repository.fetchTurn(id: turnA)?.outcome != nil)

        await gate.release()
        let eventsA = (try? await collectorA.value) ?? []
        _ = try? await collectorB.value

        // A's late completion commit lost first-writer-wins: the durable outcome stays interrupted,
        // and the finalizer delivers the interrupted outcome rather than the requested completion.
        #expect(try await repository.fetchTurn(id: turnA)?.outcome
            == .interrupted(reason: "Terminal commit exceeded terminalCommitStallLimit."))
        #expect(eventsA.contains { if case .error(.error(let message, _)) = $0 { return message == "Terminal commit exceeded terminalCommitStallLimit." }; return false })
    }
}

/// Parks only the first terminal commit; later commits pass through, so a test can hold one Turn's
/// commit open while a second Turn on the same Timeline commits normally.
private actor FirstCommitGate {
    private var entered = false
    private var continuation: CheckedContinuation<Void, Never>? // swiftlint:disable:this concurrency_stored_continuation -- test-only one-shot waiter (see docs/Concurrency/exception-manifest.md)

    func block() async {
        if entered { return }
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilEntered() async -> Bool {
        for _ in 0..<10_000 {
            if entered { return true }
            await Task.yield()
        }
        return false
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}
