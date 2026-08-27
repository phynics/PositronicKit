import Foundation
import PKContracts
import PKTestSupport
import struct PositronicKit.Thread
@testable import PositronicKit
import Synchronization
import Testing

@Suite("Facade run validation")
struct FacadeRunValidationTests {
    @Test("maxModelRounds zero fails before resolver, persistence, or provider work")
    func maxModelRoundsZeroFailsBeforeIO() async throws {
        try await assertInvalidMaxModelRounds(0)
    }

    @Test("negative maxModelRounds fails before resolver, persistence, or provider work")
    func negativeMaxModelRoundsFailsBeforeIO() async throws {
        try await assertInvalidMaxModelRounds(-3)
    }

    @Test("missing required agent fails before input persistence or provider execution")
    func missingRequiredAgentFailsBeforeIO() async throws {
        let harness = try await makeAgentHarness(policy: .failRequired)
        let agentID = UUID()

        await expectMissingAgent(agentID) {
            _ = try await harness.kit.run(TurnRequest(
                threadID: harness.threadID,
                message: "must not persist",
            ), agentID: agentID, executionKind: .agentManaged)
        }

        #expect(try await harness.persistence.fetchMessages(for: harness.threadID).isEmpty)
        #expect(harness.languageModel.generationCaptureHistory.isEmpty)
        #expect(await harness.agentStore.fetchCount == 1)
    }

    @Test("missing required agent is validated before provider readiness")
    func missingRequiredAgentPrecedesProviderReadiness() async throws {
        let harness = try await makeAgentHarness(policy: .failRequired)
        let agentID = UUID()
        harness.languageModel.mockIsConfigured = false

        await expectMissingAgent(agentID) {
            _ = try await harness.kit.run(TurnRequest(
                threadID: harness.threadID,
                message: "agent validation wins",
            ), agentID: agentID, executionKind: .agentManaged)
        }

        #expect(try await harness.persistence.fetchMessages(for: harness.threadID).isEmpty)
        #expect(harness.languageModel.generationCaptureHistory.isEmpty)
        #expect(await harness.agentStore.fetchCount == 1)
    }

    @Test("managed authority rejects a missing attached agent even when preparation warnings are allowed")
    func managedAuthorityRejectsMissingAttachedAgent() async throws {
        let harness = try await makeAgentHarness(policy: .continueWithWarnings)
        let agentID = UUID()
        var thread = try #require(try await harness.persistence.fetchThread(id: harness.threadID))
        thread.attachedAgentID = agentID
        try await harness.persistence.saveThread(thread)
        await expectMissingAgent(agentID) {
            _ = try await harness.kit.run(TurnRequest(
                threadID: harness.threadID,
                message: "must not run without authority",
            ), agentID: agentID, executionKind: .agentManaged)
        }

        #expect(await harness.agentStore.fetchCount == 2)
        #expect(harness.languageModel.generationCaptureHistory.isEmpty)
        #expect(try await harness.persistence.fetchMessages(for: harness.threadID).isEmpty)
    }

    @Test("existing agent is validated for attachment and immutable admission authority")
    func existingAgentIsValidatedForAdmission() async throws {
        let description = "unique preflight agent description"
        let agent = Agent(
            name: "Preflight Agent",
            description: description,
            privateThreadID: UUID(),
        )
        let harness = try await makeAgentHarness(policy: .failRequired, agent: agent)
        try await harness.kit.agentManager.attach(agentID: agent.id, to: harness.threadID)
        harness.languageModel.mockClient.nextResponse = "resolved"

        let stream = try await harness.kit.run(TurnRequest(
            threadID: harness.threadID,
            message: "use the resolved agent",
        ), agentID: agent.id, executionKind: .agentManaged)
        _ = try await stream.collect()

        #expect(await harness.agentStore.fetchCount == 3)
        let prompt = try #require(harness.languageModel.lastGenerationCapture)
            .messages
            .map(\.content)
            .joined(separator: "\n")
        #expect(prompt.contains(description))
    }

    @Test("required-agent preflight failure releases the request identifier for retry")
    func requiredAgentFailureReleasesRequestID() async throws {
        let harness = try await makeAgentHarness(policy: .failRequired)
        let agent = Agent(
            name: "Retry Agent",
            description: "available on retry",
            privateThreadID: UUID(),
        )
        let requestID = UUID()

        await expectMissingAgent(agent.id) {
            _ = try await harness.kit.run(TurnRequest(
                threadID: harness.threadID,
                requestID: requestID,
                message: "retryable input",
            ), agentID: agent.id, executionKind: .agentManaged)
        }

        try await harness.agentStore.saveAgent(agent)
        try await harness.kit.agentManager.attach(agentID: agent.id, to: harness.threadID)
        harness.languageModel.mockClient.nextResponse = "retried"
        let stream = try await harness.kit.run(TurnRequest(
            threadID: harness.threadID,
            requestID: requestID,
            message: "retryable input",
        ), agentID: agent.id, executionKind: .agentManaged)
        _ = try await stream.collect()

        #expect(await harness.agentStore.fetchCount == 4)
        #expect(harness.languageModel.generationCaptureHistory.count == 1)
    }

    @Test("cancelling facade run iteration cancels the provider and clears its task registration")
    func cancellingFacadeRunCancelsProviderAndRegistry() async throws {
        let probe = RunTerminationProbe()
        let languageModel = MockLLMService()
        languageModel.stubbedStream = AsyncThrowingStream { continuation in
            continuation.onTermination = { @Sendable _ in
                probe.recordTermination()
            }
            continuation.yield(GenerationStreamResultFactory.textChunk("provider-started"))
        }
        let kit = PositronicKit(configuration: .init(
            provider: .init(languageModel: languageModel),
            persistence: .inMemory(),
        ))
        let thread = try await kit.threadManager.createThread()
        let stream = try await kit.run(TurnRequest(
            threadID: thread.id,
            message: "cancel this run",
        ))
        let consumer = Task {
            for try await event in stream {
                if case let .delta(.generation(text)) = event,
                   text == "provider-started" {
                    probe.markStarted()
                }
            }
        }
        defer {
            consumer.cancel()
            probe.releaseAll()
        }

        await probe.waitUntilStarted()
        #expect(await kit.threadManager.hasActiveTask(for: thread.id))
        let activeTaskSnapshot = await kit.threadManager.activeTaskCompletion(for: thread.id)
        let activeTask = try #require(activeTaskSnapshot)
        #expect(probe.terminationCount == 0)

        consumer.cancel()
        await probe.waitUntilTerminated()
        _ = await consumer.result
        _ = await activeTask.value

        #expect(probe.terminationCount == 1)
        #expect(await kit.threadManager.hasActiveTask(for: thread.id) == false)
    }

    private func assertInvalidMaxModelRounds(_ maxModelRounds: Int) async throws {
        let languageModel = MockLLMService()
        let messageStore = FailingMessageStore()
        let threadStore = FailingThreadPersistence(fetchFails: true)
        let kit = PositronicKit(configuration: .init(
            provider: .init(languageModel: languageModel),
            persistence: .init(
                runtimeRepository: InMemoryThreadRuntimeRepository(),
            ),
        ))

        await #expect(throws: TurnError.invalidMaxModelRounds(maxModelRounds)) {
            _ = try await kit.run(TurnRequest(
                threadID: UUID(),
                message: "must not reach I/O",
                maxModelRounds: maxModelRounds,
            ))
        }

        #expect(threadStore.fetchAttemptCount == 0)
        #expect(messageStore.attemptedMessages.isEmpty)
        #expect(languageModel.generationRequestHistory.isEmpty)
        #expect(languageModel.generationCaptureHistory.isEmpty)
    }

    private func makeAgentHarness(
        policy: TurnDegradationPolicy,
        agent: Agent? = nil,
    ) async throws -> AgentHarness {
        let languageModel = MockLLMService()
        let persistence = MockPersistenceService()
        let agentStore = CountingAgentStore(agent: agent)
        let kit = PositronicKit(configuration: .init(
            provider: .init(languageModel: languageModel),
            persistence: .init(
                runtimeRepository: persistence,
                workspacePersistence: persistence,
                toolPersistence: persistence,
                agentStore: agentStore,
                requestOriginStore: persistence,
            ),
            runtime: .init(degradationPolicy: policy),
        ))
        let thread = try await kit.threadManager.createThread()
        return AgentHarness(
            kit: kit,
            languageModel: languageModel,
            persistence: persistence,
            agentStore: agentStore,
            threadID: thread.id,
        )
    }

    private func expectMissingAgent(
        _ expectedID: UUID,
        operation: () async throws -> Void,
    ) async {
        do {
            try await operation()
            Issue.record("Expected AgentError.agentNotFound")
        } catch let AgentError.agentNotFound(actualID) {
            #expect(actualID == expectedID)
        } catch {
            Issue.record("Expected AgentError.agentNotFound, got \(error)")
        }
    }
}

private struct AgentHarness {
    let kit: PositronicKit
    let languageModel: MockLLMService
    let persistence: MockPersistenceService
    let agentStore: CountingAgentStore
    let threadID: UUID
}

private actor CountingAgentStore: AgentStoreProtocol {
    private var instances: [UUID: Agent]
    private(set) var fetchCount = 0

    init(agent: Agent?) {
        instances = agent.map { [$0.id: $0] } ?? [:]
    }

    func saveAgent(_ instance: Agent) async throws {
        instances[instance.id] = instance
    }

    func fetchAgent(id: UUID) async throws -> Agent? {
        fetchCount += 1
        return instances[id]
    }

    func fetchAllAgents() async throws -> [Agent] {
        Array(instances.values)
    }

    func deleteAgent(id: UUID) async throws {
        instances.removeValue(forKey: id)
    }

    func fetchThreads(attachedToAgent _: UUID) async throws -> [Thread] {
        []
    }
}

private final class RunTerminationProbe: Sendable {
    private let started = RunTestSignal()
    private let terminated = RunTestSignal()
    private let count = Mutex(0)

    var terminationCount: Int {
        count.withLock { $0 }
    }

    func markStarted() {
        started.signal()
    }

    func waitUntilStarted() async {
        await started.wait()
    }

    func recordTermination() {
        count.withLock { $0 += 1 }
        terminated.signal()
    }

    func waitUntilTerminated() async {
        await terminated.wait()
    }

    func releaseAll() {
        started.signal()
        terminated.signal()
    }
}

private final class RunTestSignal: Sendable {
    private struct State {
        var isSignaled = false
        var waiter: CheckedContinuation<Void, Never>? // swiftlint:disable:this concurrency_stored_continuation -- Mutex/actor lifecycle state machine (see docs/Concurrency/exception-manifest.md)
    }

    private let state = Mutex(State())

    func wait() async {
        await withCheckedContinuation { continuation in
            let shouldResume = state.withLock { state in
                guard !state.isSignaled else { return true }
                precondition(state.waiter == nil)
                state.waiter = continuation
                return false
            }
            if shouldResume {
                continuation.resume()
            }
        }
    }

    func signal() {
        let waiter = state.withLock { state in
            guard !state.isSignaled else { return nil as CheckedContinuation<Void, Never>? }
            state.isSignaled = true
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume()
    }
}
