import Foundation
import PKShared
import PKTestSupport
import struct PositronicKit.Thread
@testable import PositronicKit
import Synchronization
import Testing

@Suite("Facade run validation")
struct FacadeRunValidationTests {
    @Test("maxTurns zero fails before resolver, persistence, or provider work")
    func maxTurnsZeroFailsBeforeIO() async throws {
        try await assertInvalidMaxTurns(0)
    }

    @Test("negative maxTurns fails before resolver, persistence, or provider work")
    func negativeMaxTurnsFailsBeforeIO() async throws {
        try await assertInvalidMaxTurns(-3)
    }

    @Test("missing required agent fails before input persistence or provider execution")
    func missingRequiredAgentFailsBeforeIO() async throws {
        let harness = try await makeAgentHarness(policy: .failRequired)
        let agentID = UUID()

        await expectMissingAgent(agentID) {
            _ = try await harness.kit.run(ChatRunRequest(
                threadID: harness.threadID,
                message: "must not persist",
                agentInstanceID: agentID,
            ))
        }

        #expect(try await harness.persistence.fetchMessages(for: harness.threadID).isEmpty)
        #expect(harness.languageModel.chatCaptureHistory.isEmpty)
        #expect(await harness.agentStore.fetchCount == 1)
    }

    @Test("missing required agent is validated before provider readiness")
    func missingRequiredAgentPrecedesProviderReadiness() async throws {
        let harness = try await makeAgentHarness(policy: .failRequired)
        let agentID = UUID()
        harness.languageModel.mockIsConfigured = false

        await expectMissingAgent(agentID) {
            _ = try await harness.kit.run(ChatRunRequest(
                threadID: harness.threadID,
                message: "agent validation wins",
                agentInstanceID: agentID,
            ))
        }

        #expect(try await harness.persistence.fetchMessages(for: harness.threadID).isEmpty)
        #expect(harness.languageModel.chatCaptureHistory.isEmpty)
        #expect(await harness.agentStore.fetchCount == 1)
    }

    @Test("missing agent continues with a warning when configured")
    func missingAgentContinuesWithWarning() async throws {
        let harness = try await makeAgentHarness(policy: .continueWithWarnings)
        let agentID = UUID()
        harness.languageModel.mockClient.nextResponse = "continued"

        let stream = try await harness.kit.run(ChatRunRequest(
            threadID: harness.threadID,
            message: "continue without agent",
            agentInstanceID: agentID,
        ))
        let events = try await stream.collect()

        let firstEvent = try #require(events.first)
        guard case let .meta(.generationContext(metadata)) = firstEvent else {
            Issue.record("Expected initial generation-context event, got \(firstEvent)")
            return
        }
        let diagnostic = try #require(metadata.diagnostics.first)
        #expect(metadata.diagnostics.count == 1)
        #expect(diagnostic.dependency == .agent)
        #expect(diagnostic.operation == "fetchAgentInstance")
        #expect(diagnostic.entityID == agentID.uuidString)
        #expect(diagnostic.errorIdentity?.domain == PKErrorDomain.agent)
        #expect(diagnostic.errorIdentity?.code == 5001)

        #expect(await harness.agentStore.fetchCount == 1)
        #expect(harness.languageModel.chatCaptureHistory.count == 1)
        let messages = try await harness.persistence.fetchMessages(for: harness.threadID)
        #expect(messages.map(\.role) == ["user", "assistant"])
    }

    @Test("existing agent is fetched once and reused in the prompt")
    func existingAgentIsFetchedOnceAndReused() async throws {
        let description = "unique preflight agent description"
        let agent = AgentInstance(
            name: "Preflight Agent",
            description: description,
            privateThreadID: UUID(),
        )
        let harness = try await makeAgentHarness(policy: .failRequired, agent: agent)
        try await harness.kit.agentInstanceManager.attach(agentID: agent.id, to: harness.threadID)
        harness.languageModel.mockClient.nextResponse = "resolved"

        let stream = try await harness.kit.run(ChatRunRequest(
            threadID: harness.threadID,
            message: "use the resolved agent",
            agentInstanceID: agent.id,
        ))
        _ = try await stream.collect()

        #expect(await harness.agentStore.fetchCount == 2)
        let prompt = try #require(harness.languageModel.lastChatCapture)
            .messages
            .map(\.content)
            .joined(separator: "\n")
        #expect(prompt.contains(description))
    }

    @Test("required-agent preflight failure releases the send identifier for retry")
    func requiredAgentFailureReleasesSendID() async throws {
        let harness = try await makeAgentHarness(policy: .failRequired)
        let agent = AgentInstance(
            name: "Retry Agent",
            description: "available on retry",
            privateThreadID: UUID(),
        )
        let sendID = UUID()

        await expectMissingAgent(agent.id) {
            _ = try await harness.kit.run(ChatRunRequest(
                threadID: harness.threadID,
                sendID: sendID,
                message: "retryable input",
                agentInstanceID: agent.id,
            ))
        }

        try await harness.agentStore.saveAgentInstance(agent)
        try await harness.kit.agentInstanceManager.attach(agentID: agent.id, to: harness.threadID)
        harness.languageModel.mockClient.nextResponse = "retried"
        let stream = try await harness.kit.run(ChatRunRequest(
            threadID: harness.threadID,
            sendID: sendID,
            message: "retryable input",
            agentInstanceID: agent.id,
        ))
        _ = try await stream.collect()

        #expect(await harness.agentStore.fetchCount == 3)
        #expect(harness.languageModel.chatCaptureHistory.count == 1)
    }

    @Test("cancelling facade run iteration cancels the provider and clears its task registration")
    func cancellingFacadeRunCancelsProviderAndRegistry() async throws {
        let probe = RunTerminationProbe()
        let languageModel = MockLLMService()
        languageModel.stubbedStream = AsyncThrowingStream { continuation in
            continuation.onTermination = { @Sendable _ in
                probe.recordTermination()
            }
            continuation.yield(ChatStreamResultFactory.textChunk("provider-started"))
        }
        let kit = PositronicKit(configuration: .init(
            provider: .init(languageModel: languageModel),
            persistence: .inMemory(),
        ))
        let thread = try await kit.threadManager.createThread()
        let stream = try await kit.run(ChatRunRequest(
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

    private func assertInvalidMaxTurns(_ maxTurns: Int) async throws {
        let languageModel = MockLLMService()
        let messageStore = FailingMessageStore()
        let threadStore = FailingThreadPersistence(fetchFails: true)
        let kit = PositronicKit(configuration: .init(
            provider: .init(languageModel: languageModel),
            persistence: .init(
                messageStore: messageStore,
                threadPersistence: threadStore,
            ),
        ))

        await #expect(throws: ChatRunError.invalidMaxTurns(maxTurns)) {
            _ = try await kit.run(ChatRunRequest(
                threadID: UUID(),
                message: "must not reach I/O",
                maxTurns: maxTurns,
            ))
        }

        #expect(threadStore.fetchAttemptCount == 0)
        #expect(messageStore.attemptedMessages.isEmpty)
        #expect(languageModel.chatRequestHistory.isEmpty)
        #expect(languageModel.chatCaptureHistory.isEmpty)
        #expect(languageModel.sendMessageCaptureHistory.isEmpty)
    }

    private func makeAgentHarness(
        policy: TurnDegradationPolicy,
        agent: AgentInstance? = nil,
    ) async throws -> AgentHarness {
        let languageModel = MockLLMService()
        let persistence = MockPersistenceService()
        let agentStore = CountingAgentInstanceStore(agent: agent)
        let kit = PositronicKit(configuration: .init(
            provider: .init(languageModel: languageModel),
            persistence: .init(
                messageStore: persistence,
                threadPersistence: persistence,
                workspacePersistence: persistence,
                memoryStore: persistence,
                toolPersistence: persistence,
                agentInstanceStore: agentStore,
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
            Issue.record("Expected AgentInstanceError.instanceNotFound")
        } catch let AgentInstanceError.instanceNotFound(actualID) {
            #expect(actualID == expectedID)
        } catch {
            Issue.record("Expected AgentInstanceError.instanceNotFound, got \(error)")
        }
    }
}

private struct AgentHarness {
    let kit: PositronicKit
    let languageModel: MockLLMService
    let persistence: MockPersistenceService
    let agentStore: CountingAgentInstanceStore
    let threadID: UUID
}

private actor CountingAgentInstanceStore: AgentInstanceStoreProtocol {
    private var instances: [UUID: AgentInstance]
    private(set) var fetchCount = 0

    init(agent: AgentInstance?) {
        instances = agent.map { [$0.id: $0] } ?? [:]
    }

    func saveAgentInstance(_ instance: AgentInstance) async throws {
        instances[instance.id] = instance
    }

    func fetchAgentInstance(id: UUID) async throws -> AgentInstance? {
        fetchCount += 1
        return instances[id]
    }

    func fetchAllAgentInstances() async throws -> [AgentInstance] {
        Array(instances.values)
    }

    func deleteAgentInstance(id: UUID) async throws {
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
