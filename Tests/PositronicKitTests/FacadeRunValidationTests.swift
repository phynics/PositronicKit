import Foundation
import PKShared
import PKTestSupport
@testable import PositronicKit
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
                timelineID: harness.timelineID,
                message: "must not persist",
                agentInstanceID: agentID,
            ))
        }

        #expect(try await harness.persistence.fetchMessages(for: harness.timelineID).isEmpty)
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
                timelineID: harness.timelineID,
                message: "agent validation wins",
                agentInstanceID: agentID,
            ))
        }

        #expect(try await harness.persistence.fetchMessages(for: harness.timelineID).isEmpty)
        #expect(harness.languageModel.chatCaptureHistory.isEmpty)
        #expect(await harness.agentStore.fetchCount == 1)
    }

    @Test("missing agent continues with a warning when configured")
    func missingAgentContinuesWithWarning() async throws {
        let harness = try await makeAgentHarness(policy: .continueWithWarnings)
        harness.languageModel.mockClient.nextResponse = "continued"

        let stream = try await harness.kit.run(ChatRunRequest(
            timelineID: harness.timelineID,
            message: "continue without agent",
            agentInstanceID: UUID(),
        ))
        _ = try await stream.collect()

        #expect(await harness.agentStore.fetchCount == 1)
        #expect(harness.languageModel.chatCaptureHistory.count == 1)
        let messages = try await harness.persistence.fetchMessages(for: harness.timelineID)
        #expect(messages.map(\.role) == ["user", "assistant"])
    }

    @Test("existing agent is fetched once and reused in the prompt")
    func existingAgentIsFetchedOnceAndReused() async throws {
        let description = "unique preflight agent description"
        let agent = AgentInstance(
            name: "Preflight Agent",
            description: description,
            privateTimelineID: UUID(),
        )
        let harness = try await makeAgentHarness(policy: .failRequired, agent: agent)
        harness.languageModel.mockClient.nextResponse = "resolved"

        let stream = try await harness.kit.run(ChatRunRequest(
            timelineID: harness.timelineID,
            message: "use the resolved agent",
            agentInstanceID: agent.id,
        ))
        _ = try await stream.collect()

        #expect(await harness.agentStore.fetchCount == 1)
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
            privateTimelineID: UUID(),
        )
        let sendID = UUID()

        await expectMissingAgent(agent.id) {
            _ = try await harness.kit.run(ChatRunRequest(
                timelineID: harness.timelineID,
                sendID: sendID,
                message: "retryable input",
                agentInstanceID: agent.id,
            ))
        }

        try await harness.agentStore.saveAgentInstance(agent)
        harness.languageModel.mockClient.nextResponse = "retried"
        let stream = try await harness.kit.run(ChatRunRequest(
            timelineID: harness.timelineID,
            sendID: sendID,
            message: "retryable input",
            agentInstanceID: agent.id,
        ))
        _ = try await stream.collect()

        #expect(await harness.agentStore.fetchCount == 2)
        #expect(harness.languageModel.chatCaptureHistory.count == 1)
    }

    private func assertInvalidMaxTurns(_ maxTurns: Int) async throws {
        let languageModel = MockLLMService()
        let messageStore = FailingMessageStore()
        let timelineStore = FailingTimelinePersistence(fetchFails: true)
        let kit = PositronicKit(configuration: .init(
            provider: .init(languageModel: languageModel),
            persistence: .init(
                messageStore: messageStore,
                timelinePersistence: timelineStore,
            ),
        ))

        await #expect(throws: ChatRunError.invalidMaxTurns(maxTurns)) {
            _ = try await kit.run(ChatRunRequest(
                timelineID: UUID(),
                message: "must not reach I/O",
                maxTurns: maxTurns,
            ))
        }

        #expect(timelineStore.fetchAttemptCount == 0)
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
                timelinePersistence: persistence,
                workspacePersistence: persistence,
                memoryStore: persistence,
                toolPersistence: persistence,
                agentInstanceStore: agentStore,
                requestOriginStore: persistence,
            ),
            runtime: .init(degradationPolicy: policy),
        ))
        let timeline = try await kit.timelineManager.createTimeline()
        return AgentHarness(
            kit: kit,
            languageModel: languageModel,
            persistence: persistence,
            agentStore: agentStore,
            timelineID: timeline.id,
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
    let timelineID: UUID
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

    func fetchTimelines(attachedToAgent _: UUID) async throws -> [Timeline] {
        []
    }
}
