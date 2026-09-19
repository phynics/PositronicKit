import Foundation
import PKContracts
import PKTestSupport
@testable import PositronicKit
import Testing

/// ADR 0010 regression coverage: terminal commits run in a runtime-owned finalizer, so a hung
/// host store bounds how long a Timeline stays busy, not how long eviction takes; and admission
/// classifies an active Turn this process does not own as an orphan and interrupts it.
@Suite("Turn finalizer and Timeline liveness (ADR 0010)", .tags(.integration))
struct TurnFinalizerLivenessTests {
    @Test("Timeline eviction returns while the terminal commit is hung")
    func evictionIsNotBlockedByHungCommit() async throws {
        let persistence = MockPersistenceService()
        let gate = CommitGate()
        persistence.completeTurnBlocker = { await gate.block() }
        let llm = MockLLMService()
        llm.mockClient.nextResponse = "done"
        let kit = PKRuntime(configuration: .init(
            languageModel: llm,
            persistence: .init(runtimeRepository: persistence)
        ))
        let timeline = try await kit.timelines.create(title: "Hung commit")

        let turn = try await kit.timelines.open(timeline.id).startDirectTurn(
            "finish this turn",
            context: DirectTurnContext(systemInstructions: "", contributor: .host)
        )
        let consumer = Task { for await _ in turn.events() {} }

        #expect(await gate.waitUntilBlocked(), "the terminal commit should reach the hung store")

        // Eviction cancels and drains the Turn task. The hung commit runs in the finalizer, so it
        // must not extend that wait.
        await kit.timelineManager.evictTimelineFromMemory(id: timeline.id)
        #expect(await kit.timelineManager.timeline(id: timeline.id) == nil)
        #expect(await kit.timelineManager.hasActiveTask(for: timeline.id) == false)

        await gate.release()
        consumer.cancel()
    }

    @Test("admission does not interrupt a Turn this process is still preparing")
    func admissionSparesPreparingTurn() async throws {
        let llm = MockLLMService()
        llm.mockClient.nextResponse = "prepared reply"
        let gate = PreparationGate()
        let kit = PKRuntime(configuration: .init(
            languageModel: llm,
            persistence: .inMemory(),
            runtime: .init(customization: RuntimeCustomization(turnContextSource: gate))
        ))
        let timeline = try await kit.timelines.create(title: "Prepare in-process")

        let first = Task {
            try await timeline.startDirectTurn(
                "first request",
                context: DirectTurnContext(systemInstructions: "", contributor: .host)
            )
        }
        #expect(await gate.waitUntilEntered(), "the first Turn should reach preparation")

        // A different request during preparation must stay busy, not interrupt the preparing Turn.
        let active = try #require(try await kit.runtimeRepository.fetchActiveTurn(for: timeline.id))
        do {
            _ = try await timeline.startDirectTurn(
                "second request",
                context: DirectTurnContext(systemInstructions: "", contributor: .host)
            )
            Issue.record("expected timelineBusy while the first Turn prepares")
        } catch let error as TimelineRuntimeRepositoryError {
            #expect(error == .timelineBusy(timelineID: timeline.id, activeTurnID: active.identity.turnID))
        }
        #expect(try await kit.runtimeRepository.fetchTurn(id: active.identity.turnID)?.outcome == nil,
                "the preparing Turn must not be interrupted")

        await gate.release()
        let turn = try await first.value
        _ = await turn.events().collect()
        #expect(try await kit.runtimeRepository.fetchTurn(id: turn.id)?.outcome == .completed)
    }

    @Test("admission stays busy while a commit is pending within the stall limit")
    func admissionStaysBusyWithinStallLimit() async throws {
        let persistence = MockPersistenceService()
        let gate = CommitGate()
        persistence.completeTurnBlocker = { await gate.block() }
        let llm = MockLLMService()
        llm.mockClient.nextResponse = "reply"
        let kit = PKRuntime(configuration: .init(
            languageModel: llm,
            persistence: .init(runtimeRepository: persistence)
        ))
        let timeline = try await kit.timelines.create(title: "Within stall limit")
        let turn = try await kit.timelines.open(timeline.id).startDirectTurn(
            "A",
            context: DirectTurnContext(systemInstructions: "", contributor: .host)
        )
        let consumer = Task { for await _ in turn.events() {} }
        #expect(await gate.waitUntilBlocked(), "A's commit should be parked")

        // B arrives well within the default stall limit: A's pending commit stays busy.
        do {
            _ = try await kit.timelines.open(timeline.id).startDirectTurn(
                "B",
                context: DirectTurnContext(systemInstructions: "", contributor: .host)
            )
            Issue.record("expected timelineBusy while A's commit is within the stall limit")
        } catch let error as TimelineRuntimeRepositoryError {
            #expect(error == .timelineBusy(timelineID: timeline.id, activeTurnID: turn.id))
        }
        #expect(try await persistence.fetchTurn(id: turn.id)?.outcome == nil)

        await gate.release()
        consumer.cancel()
    }

    @Test("a Turn after an interrupted hung commit completes")
    func turnAfterInterruptedHungCommitCompletes() async throws {
        let persistence = MockPersistenceService()
        let gate = HangFirstGate()
        persistence.completeTurnBlocker = { await gate.block() }
        let llm = MockLLMService()
        llm.mockClient.nextResponse = "reply"
        let kit = PKRuntime(configuration: .init(
            languageModel: llm,
            persistence: .init(runtimeRepository: persistence),
            runtime: .init(terminalCommitStallLimit: 0.05)
        ))
        let timeline = try await kit.timelines.create(title: "Hung then healthy")
        let first = try await kit.timelines.open(timeline.id).startDirectTurn(
            "A",
            context: DirectTurnContext(systemInstructions: "", contributor: .host)
        )
        let consumerA = Task { for await _ in first.events() {} }
        #expect(await gate.waitUntilEntered(), "A's commit should be parked")

        // Let the stall limit elapse, then send B: admission interrupts A and admits B.
        try await Task.sleep(for: .milliseconds(250))
        let second = try await kit.timelines.open(timeline.id).startDirectTurn(
            "B",
            context: DirectTurnContext(systemInstructions: "", contributor: .host)
        )
        _ = await second.events().collect()

        // B's stream finished and its commit landed even though A's commit is still parked, so a
        // hung commit cannot poison later Turns on the same Timeline.
        #expect(try await persistence.fetchTurn(id: second.id)?.outcome == .completed)
        let firstRecord = try #require(try await persistence.fetchTurn(id: first.id))
        #expect(firstRecord.outcome == .interrupted(reason: "Terminal commit exceeded terminalCommitStallLimit (0.05s)."))

        await gate.release()
        consumerA.cancel()
    }

    @Test("a replacement runtime does not interrupt the original runtime's pending commit")
    func replacementRuntimeSharesFinalizer() async throws {
        let persistence = MockPersistenceService()
        let gate = CommitGate()
        persistence.completeTurnBlocker = { await gate.block() }
        let llm = MockLLMService()
        llm.mockClient.nextResponse = "reply"
        let kit = PKRuntime(configuration: .init(
            languageModel: llm,
            persistence: .init(runtimeRepository: persistence)
        ))
        let timeline = try await kit.timelines.create(title: "Replacement")
        let turn = try await kit.timelines.open(timeline.id).startDirectTurn(
            "A",
            context: DirectTurnContext(systemInstructions: "", contributor: .host)
        )
        let consumer = Task { for await _ in turn.events() {} }
        #expect(await gate.waitUntilBlocked(), "A's commit should be parked")

        let replacement = kit.replacingLanguageModel(llm)
        do {
            _ = try await replacement.timelines.open(timeline.id).startDirectTurn(
                "B",
                context: DirectTurnContext(systemInstructions: "", contributor: .host)
            )
            Issue.record("expected timelineBusy through the replacement runtime")
        } catch let error as TimelineRuntimeRepositoryError {
            #expect(error == .timelineBusy(timelineID: timeline.id, activeTurnID: turn.id))
        }
        #expect(try await persistence.fetchTurn(id: turn.id)?.outcome == nil)

        await gate.release()
        consumer.cancel()
    }

    @Test("an unresolved mutating intent quarantines even without a hydrated Timeline")
    func quarantinesUnresolvedMutatingIntentOnNonHydratedTimeline() async throws {
        let persistence = MockPersistenceService()
        let llm = MockLLMService()
        llm.mockClient.nextResponse = "reply"
        let kit = PKRuntime(configuration: .init(
            languageModel: llm,
            persistence: .init(runtimeRepository: persistence)
        ))
        let timeline = try await kit.timelines.create(title: "Quarantine evidence")

        // Orphan admitted by an earlier process, with an unresolved mutating intent. The side
        // effect class is on the intent, so no tool registry is needed to classify it.
        let orphan = try await persistence.admitTurn(
            timelineID: timeline.id,
            requestID: UUID(),
            callerIntentFingerprint: "orphan",
            inputMessage: nil,
            now: Date()
        )
        try await persistence.recordToolIntent(RuntimeToolIntent(
            turnID: orphan.turn.identity.turnID,
            timelineID: timeline.id,
            toolCallID: "call-1",
            name: "write-file",
            arguments: "{}",
            modelRoundIndex: 0,
            sideEffects: .mutating,
            createdAt: Date()
        ))

        do {
            _ = try await kit.timelines.open(timeline.id).startDirectTurn(
                "next",
                context: DirectTurnContext(systemInstructions: "", contributor: .host)
            )
            Issue.record("expected timelineQuarantined")
        } catch let error as TimelineRuntimeRepositoryError {
            #expect(error == .timelineQuarantined(timelineID: timeline.id, turnID: orphan.turn.identity.turnID))
        }

        let orphanRecord = try #require(try await persistence.fetchTurn(id: orphan.turn.identity.turnID))
        #expect(orphanRecord.isQuarantined)
        #expect(orphanRecord.outcome == .interrupted(reason: "Turn was active but not owned by this runtime (orphaned)."))
    }

    @Test("a cancelled Turn still commits when the store checks cancellation")
    func cancelledTurnCommitsWhenStoreChecksCancellation() async throws {
        let llm = MockLLMService()
        llm.mockClient.nextChunks = [Array(repeating: "a", count: 100)]
        llm.mockClient.nextStreamWait = 0.05
        let persistence = MockPersistenceService()
        persistence.completeTurnChecksCancellation = true
        let kit = PKRuntime(configuration: .init(
            languageModel: llm,
            persistence: .init(runtimeRepository: persistence)
        ))
        let timeline = try await kit.timelines.create(title: "Cancel durability")
        let turn = try await kit.timelines.open(timeline.id).startDirectTurn(
            "stream",
            context: DirectTurnContext(systemInstructions: "", contributor: .host)
        )
        let consumer = Task { for await _ in turn.events() {} }
        try await Task.sleep(for: .milliseconds(150))
        await turn.cancel()
        _ = await consumer.value

        let record = try #require(try await persistence.fetchTurn(id: turn.id))
        #expect(record.outcome == .cancelled(reason: "Turn task cancelled."))
    }

    @Test("admission interrupts an orphaned active Turn and admits the next request")
    func admissionInterruptsOrphanedActiveTurn() async throws {
        let persistence = MockPersistenceService()
        let llm = MockLLMService()
        llm.mockClient.nextResponse = "done"
        let kit = PKRuntime(configuration: .init(
            languageModel: llm,
            persistence: .init(runtimeRepository: persistence)
        ))
        let timeline = try await kit.timelines.create(title: "Orphan")

        // Simulate a Turn admitted by an earlier process: the durable active pointer exists, but
        // this process has no registered task for it.
        let orphan = try await persistence.admitTurn(
            timelineID: timeline.id,
            requestID: UUID(),
            callerIntentFingerprint: "orphan",
            inputMessage: nil,
            now: Date()
        )
        #expect(orphan.disposition == .admitted)

        // New admission meets the busy pointer, classifies the unowned Turn as an orphan,
        // interrupts it, and retries once.
        let turn = try await kit.timelines.open(timeline.id).startDirectTurn(
            "next request",
            context: DirectTurnContext(systemInstructions: "", contributor: .host)
        )
        _ = await turn.events().collect()

        let orphanRecord = try #require(try await persistence.fetchTurn(id: orphan.turn.identity.turnID))
        #expect(orphanRecord.outcome == .interrupted(reason: "Turn was active but not owned by this runtime (orphaned)."))
        #expect(orphanRecord.isQuarantined == false)
        #expect(try await persistence.fetchTurn(id: turn.id)?.outcome == .completed)
    }
}

/// A gate that parks the first Turn in context contributions until the test releases it.
private actor PreparationGate: TurnContextSource {
    private var entered = false
    private var continuation: CheckedContinuation<Void, Never>? // swiftlint:disable:this concurrency_stored_continuation -- test-only one-shot waiter (see docs/Concurrency/exception-manifest.md)

    func contributions(for _: TurnContextRequest) async throws -> [TurnContextContribution] {
        entered = true
        await withCheckedContinuation { continuation = $0 }
        return []
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

/// Parks only the first terminal commit; later commits pass through immediately, so a test can
/// hold one Turn's commit open while a second Turn on the same Timeline commits normally.
private actor HangFirstGate {
    private var firstEntered = false
    private var parked = false
    private var continuation: CheckedContinuation<Void, Never>? // swiftlint:disable:this concurrency_stored_continuation -- test-only one-shot waiter (see docs/Concurrency/exception-manifest.md)

    func block() async {
        if firstEntered { return }
        firstEntered = true
        parked = true
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilEntered() async -> Bool {
        for _ in 0..<10_000 {
            if parked { return true }
            await Task.yield()
        }
        return false
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

/// A one-shot gate that parks a terminal commit until the test releases it.
private actor CommitGate {
    private var blocked = false
    private var continuation: CheckedContinuation<Void, Never>? // swiftlint:disable:this concurrency_stored_continuation -- test-only one-shot waiter (see docs/Concurrency/exception-manifest.md)

    func block() async {
        blocked = true
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilBlocked() async -> Bool {
        for _ in 0..<10_000 {
            if blocked { return true }
            await Task.yield()
        }
        return false
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}
