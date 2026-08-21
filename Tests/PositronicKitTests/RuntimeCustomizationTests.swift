import Foundation
import PKContracts
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
