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
        #expect(orphanRecord.outcome == .interrupted(reason: "Runtime recovered a Turn that was not owned by this process."))
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
