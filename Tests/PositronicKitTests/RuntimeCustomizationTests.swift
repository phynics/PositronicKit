import Foundation
import PKTestSupport
@testable import PositronicKit
import Testing

@Suite("Runtime customization")
struct RuntimeCustomizationTests {
    @Test("reserved namespaces and oversized values are rejected")
    func contributionBoundsAreEnforced() throws {
        #expect(throws: TurnContextContributionError.self) {
            _ = try TurnContextContribution(namespace: "runtime", key: "tenant", text: "x")
        }
        #expect(throws: TurnContextContributionError.self) {
            _ = try TurnContextContribution(
                namespace: "host",
                key: "payload",
                text: String(repeating: "x", count: TurnContextContribution.maximumTextCharacters + 1)
            )
        }

        let contribution = try TurnContextContribution(
            namespace: "host",
            key: "tenant.id",
            text: "berlin",
            requirement: .required
        )
        #expect(contribution.source == "runtime/host/tenant.id")
        #expect(contribution.noteName == "host.tenant.id")
        #expect(contribution.requirement == .required)
    }

    @Test("required context-source failure aborts before provider work")
    func requiredSourceFailureAbortsPreparation() async throws {
        let model = MockLLMService()
        let repository = InMemoryThreadRuntimeRepository()
        let source = FailingContextSource(requirement: .required)
        let kit = try await makeKit(
            model: model,
            repository: repository,
            customization: RuntimeCustomization(turnContextSource: source)
        )

        let thread = try await kit.threads.create(title: "Required context")
        await #expect(throws: TurnDegradationError.self) {
            _ = try await thread.startDirectTurn(
                message: "must fail",
                context: DirectTurnContext(systemInstructions: "", contributor: .host)
            )
        }
        #expect(model.mockClient.streamCallCount == 0)
        #expect(try await repository.fetchMessages(for: thread.id).isEmpty)
    }

    @Test("optional context-source failure persists a notice and continues")
    func optionalSourceFailureContinuesWithNotice() async throws {
        let model = MockLLMService()
        model.mockClient.nextResponse = "continued"
        let repository = InMemoryThreadRuntimeRepository()
        let source = FailingContextSource(requirement: .optional)
        let kit = try await makeKit(
            model: model,
            repository: repository,
            customization: RuntimeCustomization(turnContextSource: source)
        )

        let thread = try await kit.threads.create(title: "Optional context")
        let turn = try await thread.startDirectTurn(
            message: "continue",
            context: DirectTurnContext(systemInstructions: "", contributor: .host)
        )
        _ = await turn.events().collect()

        #expect(await turn.outcome() == .completed)
        let notices = try await repository.fetchNotices(turnID: turn.id)
        #expect(notices.contains { $0.kind == TurnNoticeCode.contextContributionFailed.rawValue })
        #expect(model.mockClient.streamCallCount == 1)
    }

    @Test("context contributions are rendered as bounded host notes")
    func contributionReachesPromptAsNote() async throws {
        let model = MockLLMService()
        model.mockClient.nextResponse = "noted"
        let repository = InMemoryThreadRuntimeRepository()
        let source = ContributingContextSource()
        let kit = try await makeKit(
            model: model,
            repository: repository,
            customization: RuntimeCustomization(turnContextSource: source)
        )

        let thread = try await kit.threads.create(title: "Contribution")
        let turn = try await thread.startDirectTurn(
            message: "use context",
            context: DirectTurnContext(systemInstructions: "", contributor: .host)
        )
        _ = await turn.events().collect()

        let prompt = model.mockClient.lastMessages.map(\.content).joined(separator: "\n")
        #expect(prompt.contains("tenant=berlin"))
        #expect(await turn.outcome() == .completed)
    }

    @Test("activity and outcome sinks cannot change a durable terminal outcome")
    func sinksAreBestEffortAfterDurability() async throws {
        let model = MockLLMService()
        model.mockClient.nextResponse = "reply"
        let repository = InMemoryThreadRuntimeRepository()
        let activitySink = GatedActivitySink()
        let outcomeSink = FailingOutcomeSink(repository: repository)
        let kit = try await makeKit(
            model: model,
            repository: repository,
            customization: RuntimeCustomization(
                agentActivitySink: activitySink,
                turnOutcomeSink: outcomeSink
            )
        )

        let thread = try await kit.threads.create(title: "Sinks")
        let turn = try await thread.startDirectTurn(
            message: "sink",
            context: DirectTurnContext(systemInstructions: "", contributor: .host)
        )
        await activitySink.waitUntilEntered()
        for _ in 0..<100 where model.mockClient.streamCallCount == 0 {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(model.mockClient.streamCallCount == 1)
        await activitySink.release()
        _ = await turn.events().collect()
        await activitySink.waitUntilFinished()

        #expect(await turn.outcome() == .completed)
        #expect(await outcomeSink.wasDurableAtCallback)
        let notices = try await repository.fetchNotices(turnID: turn.id)
        #expect(notices.contains { $0.kind == TurnNoticeCode.agentActivitySinkFailed.rawValue })
        #expect(notices.contains { $0.kind == TurnNoticeCode.turnOutcomeSinkFailed.rawValue })
    }

    @Test("primary activity projection queues behind private-Thread work and is idempotent")
    func primaryActivityProjectionQueuesAndDeduplicates() async throws {
        let repository = InMemoryThreadRuntimeRepository()
        let agentID = UUID()
        let privateThreadID = UUID()
        let sourceThreadID = UUID()
        let workspaceID = UUID()
        try await repository.saveThread(Thread(
            id: privateThreadID,
            title: "Private",
            attachedAgentID: agentID,
            isPrivate: true
        ))
        try await repository.saveThread(Thread(id: sourceThreadID, title: "Source"))
        try await repository.saveAgent(Agent(
            id: agentID,
            name: "Projection",
            description: "test",
            primaryWorkspaceID: workspaceID,
            privateThreadID: privateThreadID
        ))
        let active = try await repository.admitTurn(
            threadID: privateThreadID,
            requestID: UUID(),
            callerIntentFingerprint: "private-active"
        )
        let sink = PrimaryThreadActivitySink(
            agentStore: repository,
            pairStore: repository,
            runtimeRepository: repository,
            threadAuthorityCoordinator: ThreadAuthorityCoordinator(),
            loggingConfiguration: .default
        )
        let activity = PrimaryThreadActivity(
            callID: "primary-1",
            name: "read_file",
            argumentsJSON: "{\"arguments\":{}}",
            sourceThreadID: sourceThreadID,
            privateThreadID: privateThreadID,
            turnID: UUID(),
            requestID: UUID(),
            agentID: agentID,
            modelRoundIndex: 1,
            workspaceID: workspaceID,
            routing: .implicit,
            outcome: .succeeded(output: "queued output")
        )

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<4 {
                group.addTask { await sink.record(activity) }
            }
        }
        try await Task.sleep(for: .milliseconds(20))
        #expect(try await repository.fetchMessages(for: privateThreadID).isEmpty)

        _ = try await repository.completeTurn(
            turnID: active.turn.identity.turnID,
            outcome: .completed
        )
        for _ in 0..<100 {
            if try await repository.fetchMessages(for: privateThreadID).count == 2 { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        await sink.record(activity)
        try await Task.sleep(for: .milliseconds(20))
        let mirrored = try await repository.fetchMessages(for: privateThreadID)
        #expect(mirrored.count == 2)
        #expect(mirrored[0].role == "assistant")
        #expect(mirrored[1].role == "tool")
        #expect(mirrored[1].content == "queued output")
        #expect(mirrored[1].parentID == mirrored[0].id)
    }

    @Test("primary projection suppresses self-originated activity and preserves failures")
    func primaryActivityProjectionGuardsSourceAndFailure() async throws {
        let repository = InMemoryThreadRuntimeRepository()
        let agentID = UUID()
        let privateThreadID = UUID()
        let sourceThreadID = UUID()
        let workspaceID = UUID()
        try await repository.saveThread(Thread(id: privateThreadID, isPrivate: true))
        try await repository.saveThread(Thread(id: sourceThreadID))
        try await repository.saveAgent(Agent(
            id: agentID,
            name: "Projection",
            description: "test",
            primaryWorkspaceID: workspaceID,
            privateThreadID: privateThreadID
        ))
        let sink = PrimaryThreadActivitySink(
            agentStore: repository,
            pairStore: repository,
            runtimeRepository: repository,
            threadAuthorityCoordinator: ThreadAuthorityCoordinator(),
            loggingConfiguration: .default
        )
        let ownActivity = PrimaryThreadActivity(
            callID: "self",
            name: "read_file",
            argumentsJSON: "{}",
            sourceThreadID: privateThreadID,
            privateThreadID: privateThreadID,
            turnID: UUID(),
            requestID: UUID(),
            agentID: agentID,
            modelRoundIndex: 0,
            workspaceID: workspaceID,
            routing: .implicit,
            outcome: .succeeded(output: "must not mirror")
        )
        await sink.record(ownActivity)
        try await Task.sleep(for: .milliseconds(20))
        #expect(try await repository.fetchMessages(for: privateThreadID).isEmpty)

        let failedActivity = PrimaryThreadActivity(
            callID: "failed",
            name: "read_file",
            argumentsJSON: "{}",
            sourceThreadID: sourceThreadID,
            privateThreadID: privateThreadID,
            turnID: UUID(),
            requestID: UUID(),
            agentID: agentID,
            modelRoundIndex: 0,
            workspaceID: workspaceID,
            routing: .explicit,
            outcome: .failed(output: "", error: "permission denied")
        )
        await sink.record(failedActivity)
        for _ in 0..<100 {
            if try await repository.fetchMessages(for: privateThreadID).count == 2 { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        let messages = try await repository.fetchMessages(for: privateThreadID)
        #expect(messages.count == 2)
        #expect(messages[1].content == "Error: permission denied")
    }

    @Test("primary projection pair append is atomic on tool-side conflict")
    func primaryPairAppendIsAtomic() async throws {
        let repository = InMemoryThreadRuntimeRepository()
        let threadID = UUID()
        let assistantID = UUID()
        let assistant = ThreadMessage(
            id: assistantID,
            threadID: threadID,
            role: .assistant,
            content: "",
            toolCalls: "[]"
        )
        let conflictingTool = ThreadMessage(
            id: assistantID,
            threadID: threadID,
            role: .tool,
            content: "conflict",
            parentID: assistantID,
            toolCallID: "call"
        )

        await #expect(throws: ThreadRuntimeRepositoryError.self) {
            try await repository.appendPrimaryThreadPair(assistant: assistant, tool: conflictingTool)
        }
        #expect(try await repository.fetchMessages(for: threadID).isEmpty)
    }

    private func makeKit(
        model: MockLLMService,
        repository: InMemoryThreadRuntimeRepository,
        customization: RuntimeCustomization
    ) async throws -> PositronicKit {
        PositronicKit(configuration: .init(
            provider: .init(languageModel: model),
            persistence: .init(runtimeRepository: repository),
            runtime: .init(customization: customization)
        ))
    }
}

private enum ContextSourceFailure: Error, Sendable {
    case unavailable
}

private struct FailingContextSource: TurnContextSource {
    let requirement: TurnContextContributionRequirement

    var failureRequirement: TurnContextContributionRequirement { requirement }

    func contributions(for _: TurnContextRequest) async throws -> [TurnContextContribution] {
        throw ContextSourceFailure.unavailable
    }
}

private struct ContributingContextSource: TurnContextSource {
    func contributions(for _: TurnContextRequest) async throws -> [TurnContextContribution] {
        [try TurnContextContribution(namespace: "host", key: "tenant", text: "tenant=berlin")]
    }
}

private actor GatedActivitySink: AgentActivitySink {
    private var enteredCount = 0
    private var finishedCount = 0
    private var isReleased = false

    func record(_: AgentActivity) async throws {
        enteredCount += 1
        while !isReleased {
            try? await Task.sleep(for: .milliseconds(1))
        }
        finishedCount += 1
        throw ContextSourceFailure.unavailable
    }

    func waitUntilEntered() async {
        while enteredCount == 0 {
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    func release() {
        isReleased = true
    }

    func waitUntilFinished() async {
        while finishedCount < enteredCount || enteredCount < 2 {
            try? await Task.sleep(for: .milliseconds(1))
        }
    }
}

private actor FailingOutcomeSink: TurnOutcomeSink {
    let repository: InMemoryThreadRuntimeRepository
    private(set) var wasDurableAtCallback = false

    init(repository: InMemoryThreadRuntimeRepository) {
        self.repository = repository
    }

    func record(_ outcome: TurnOutcomeRecord) async throws {
        wasDurableAtCallback = (try await repository.fetchTurn(id: outcome.turnID))?.outcome != nil
        throw ContextSourceFailure.unavailable
    }
}
