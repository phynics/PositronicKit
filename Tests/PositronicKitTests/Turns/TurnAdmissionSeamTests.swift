import Foundation
import PKContracts
import PKTestSupport
import PKUtilities
@testable import PositronicKit
import Testing

// No `.serialized` marker: every test builds a fresh in-memory repository and a unique
// workspace root (issue #155), so tests are independent and may run in parallel.
@Suite(.tags(.integration))
struct TurnAdmissionSeamTests {
    @Test("managed admission captures authoritative Agent context")
    func managedAdmissionCapturesAuthority() async throws {
        let agent = Agent(name: "Managed", description: "test", privateTimelineID: UUID())
        let harness = try await makeHarness(attachedAgent: agent)
        let requestID = UUID()
        let turnID = UUID()
        let result = try await harness.engine.preparation.admitTurn(TurnPreparation.TurnAdmissionRequest(
            timelineID: harness.timelineID,
            turnID: turnID,
            requestID: requestID,
            inputMessage: TimelineMessage(
                id: requestID,
                timelineID: harness.timelineID,
                role: .user,
                content: "managed"
            ),
            executionKind: .agentManaged,
            agentID: agent.id,
            callerIntentFingerprint: "managed"
        ))

        #expect(result.agent?.id == agent.id)
        #expect(result.agentContext?.identity.agentID == agent.id)
        if case .admitted = result.disposition {} else {
            Issue.record("Expected a new managed Turn admission")
        }
        let record = try #require(try await harness.repository.fetchTurn(id: turnID))
        #expect(record.executionKind == .agentManaged)
        #expect(record.capturedAgentID == agent.id)
    }

    @Test("direct admission captures detached Timeline authority without Agent context")
    func directAdmissionCapturesDetachedAuthority() async throws {
        let harness = try await makeHarness()
        let requestID = UUID()
        let turnID = UUID()
        let result = try await harness.engine.preparation.admitTurn(TurnPreparation.TurnAdmissionRequest(
            timelineID: harness.timelineID,
            turnID: turnID,
            requestID: requestID,
            inputMessage: nil,
            executionKind: .direct,
            agentID: nil,
            callerIntentFingerprint: "direct"
        ))

        #expect(result.agent == nil)
        #expect(result.agentContext == nil)
        if case .admitted = result.disposition {} else {
            Issue.record("Expected a new direct Turn admission")
        }
        let record = try #require(try await harness.repository.fetchTurn(id: turnID))
        #expect(record.executionKind == .direct)
        #expect(record.capturedAgentID == nil)
    }

    @Test("repeated caller intent joins the atomically admitted Turn")
    func repeatedCallerIntentJoins() async throws {
        let harness = try await makeHarness()
        let requestID = UUID()
        let firstTurnID = UUID()
        let first = try await harness.engine.preparation.admitTurn(makeRequest(
            timelineID: harness.timelineID,
            turnID: firstTurnID,
            requestID: requestID,
            content: "same"
        ))
        let joined = try await harness.engine.preparation.admitTurn(makeRequest(
            timelineID: harness.timelineID,
            turnID: UUID(),
            requestID: requestID,
            content: "same"
        ))

        if case .admitted = first.disposition {} else {
            Issue.record("Expected the first request to be admitted")
        }
        if case let .existing(admission) = joined.disposition {
            if case .joined = admission.disposition {} else {
                Issue.record("Expected an idempotent join disposition")
            }
            #expect(admission.turn.identity.turnID == firstTurnID)
        } else {
            Issue.record("Expected the second request to join the first Turn")
        }
        #expect(try await harness.repository.fetchMessages(for: harness.timelineID).count == 1)
    }

    @Test("a terminal repository Turn is replayed, not re-executed, for the same request")
    func terminalRequestReplays() async throws {
        let harness = try await makeHarness()
        let requestID = UUID()
        let turnID = UUID()
        _ = try await harness.engine.preparation.admitTurn(makeRequest(
            timelineID: harness.timelineID,
            turnID: turnID,
            requestID: requestID,
            content: "terminal"
        ))
        _ = try await harness.repository.completeTurn(
            turnID: turnID,
            outcome: .completed,
            finalMessage: nil,
            terminalHandle: nil,
            now: Date()
        )

        let replayed = try await harness.engine.preparation.admitTurn(makeRequest(
            timelineID: harness.timelineID,
            turnID: UUID(),
            requestID: requestID,
            content: "terminal"
        ))
        if case let .existing(admission) = replayed.disposition {
            if case .replayed = admission.disposition {} else {
                Issue.record("Expected a terminal replay disposition")
            }
            #expect(admission.turn.identity.turnID == turnID)
        } else {
            Issue.record("Expected the terminal Turn to be replayed")
        }
        #expect(try await harness.repository.fetchMessages(for: harness.timelineID).count == 1)
    }

    @Test("reserved call_tool validation happens before admission")
    func reservedToolIsRejectedBeforeAdmission() async throws {
        let harness = try await makeHarness()

        await #expect(throws: ToolError.reservedToolName("call_tool")) {
            _ = try await harness.engine.preparation.prepareTurn(
                TurnExecutionRequest(
                    TurnRequest(
                        timelineID: harness.timelineID,
                        requestID: UUID(),
                        message: "must not admit",
                        tools: [ReservedCallTool()],
                        systemInstructions: "",
                        maxModelRounds: 1
                    ),
                    executionKind: .direct,
                    contributors: [.host]
                ),
                turnID: UUID(),
                agent: nil,
                agentDiagnostics: []
            )
        }

        #expect(try await harness.repository.fetchMessages(for: harness.timelineID).isEmpty)
        #expect(try await harness.repository.fetchActiveTurn(for: harness.timelineID) == nil)
    }

    @Test("post-admission preparation failure retains input and records a failed Turn")
    func preparationFailureRetainsAtomicInput() async throws {
        let harness = try await makeHarness()
        let requestID = UUID()
        let turnID = UUID()

        await #expect(throws: Error.self) {
            _ = try await harness.engine.preparation.prepareTurn(
                TurnExecutionRequest(
                    TurnRequest(
                        timelineID: harness.timelineID,
                        requestID: requestID,
                        message: "retained input",
                        toolOutputs: [ToolOutputSubmission(toolCallID: "missing", output: "result")],
                        systemInstructions: "",
                        maxModelRounds: 1
                    ),
                    executionKind: .direct,
                    contributors: [.host]
                ),
                turnID: turnID,
                agent: nil,
                agentDiagnostics: []
            )
        }

        let messages = try await harness.repository.fetchMessages(for: harness.timelineID)
        #expect(messages.filter { $0.role == "user" }.map(\.content) == ["retained input"])
        let record = try #require(try await harness.repository.fetchTurn(id: turnID))
        #expect(record.outcome == .failed(message: "Turn preparation failed before execution."))
        #expect(try await harness.repository.fetchActiveTurn(for: harness.timelineID) == nil)
    }

    @Test("preparation failure releases reserved external tool output IDs")
    func preparationFailureReleasesToolReservation() async throws {
        let harness = try await makeHarness()
        let callID = "release-me"
        let danglingID = "still-dangling"
        let calls = try SerializationUtils.jsonEncoder.encode([
            ToolCall(id: callID, name: "external_tool", arguments: [:]),
            ToolCall(id: danglingID, name: "external_tool", arguments: [:]),
        ])
        try await harness.repository.saveMessage(TimelineMessage(
            timelineID: harness.timelineID,
            role: .assistant,
            content: "",
            toolCalls: String(decoding: calls, as: UTF8.self)
        ))

        await #expect(throws: Error.self) {
            _ = try await harness.engine.preparation.prepareTurn(
                TurnExecutionRequest(
                    TurnRequest(
                        timelineID: harness.timelineID,
                        requestID: UUID(),
                        message: "",
                        toolOutputs: [ToolOutputSubmission(toolCallID: callID, output: "result")],
                        systemInstructions: "",
                        maxModelRounds: 1
                    ),
                    executionKind: .direct,
                    contributors: [.host]
                ),
                turnID: UUID(),
                agent: nil,
                agentDiagnostics: []
            )
        }

        let retryable = try await harness.engine.dependencies.submissionGate.validate(
            [ToolOutputSubmission(toolCallID: callID, output: "result")],
            timelineID: harness.timelineID,
            runtimeRepository: harness.repository
        )
        #expect(retryable.map(\.toolCallID) == [callID])
        await harness.engine.dependencies.submissionGate.releaseReservations(
            timelineID: harness.timelineID,
            toolCallIds: [callID]
        )
    }

    /// Regression for D-03(b): a `validate` call that reserves several outputs and then throws
    /// partway through the batch used to leave the earlier, already-reserved outputs stranded —
    /// the caller only receives the reservation list on success, so it has no way to release
    /// what a partially-failed call already reserved internally. `validate` now self-cleans: on
    /// its own throw, it releases everything it reserved during that same call before rethrowing.
    @Test("A partially invalid validate batch releases its own earlier reservations")
    func partiallyInvalidValidateBatchReleasesEarlierReservations() async throws {
        let harness = try await makeHarness()
        let goodCallID = "reserved-then-batch-fails"
        let calls = try SerializationUtils.jsonEncoder.encode([
            ToolCall(id: goodCallID, name: "external_tool", arguments: [:]),
        ])
        try await harness.repository.saveMessage(TimelineMessage(
            timelineID: harness.timelineID,
            role: .assistant,
            content: "",
            toolCalls: String(decoding: calls, as: UTF8.self)
        ))

        let gate = harness.engine.dependencies.submissionGate
        await #expect(throws: ToolError.self) {
            _ = try await gate.validate(
                [
                    ToolOutputSubmission(toolCallID: goodCallID, output: "result"),
                    ToolOutputSubmission(toolCallID: "no-such-call", output: "result"),
                ],
                timelineID: harness.timelineID,
                runtimeRepository: harness.repository
            )
        }

        // If the first output's reservation leaked, this second validate would see it as already
        // reserved and drop it from the pending set, so `retryable` would come back empty.
        let retryable = try await gate.validate(
            [ToolOutputSubmission(toolCallID: goodCallID, output: "result")],
            timelineID: harness.timelineID,
            runtimeRepository: harness.repository
        )
        #expect(retryable.map(\.toolCallID) == [goodCallID])
        await gate.releaseReservations(timelineID: harness.timelineID, toolCallIds: [goodCallID])
    }

    private func makeRequest(
        timelineID: UUID,
        turnID: UUID,
        requestID: UUID,
        content: String
    ) -> TurnPreparation.TurnAdmissionRequest {
        TurnPreparation.TurnAdmissionRequest(
            timelineID: timelineID,
            turnID: turnID,
            requestID: requestID,
            inputMessage: TimelineMessage(
                id: requestID,
                timelineID: timelineID,
                role: .user,
                content: content
            ),
            executionKind: .direct,
            agentID: nil,
            callerIntentFingerprint: "same-intent"
        )
    }

    private func makeHarness(attachedAgent: Agent? = nil) async throws -> AdmissionHarness {
        let repository = InMemoryTimelineRuntimeRepository()
        let backing = MockPersistenceService()
        let timelineManager = TimelineManager(
            stores: .init(
                timelineStore: repository,
                messageStore: repository,
                workspaceStore: backing,
                workspaceBindingRepository: repository,
                runtimeRepository: repository,
                toolPersistence: backing
            ),
            workspaceProfile: .hostManaged(root: FileManager.default.temporaryDirectory.appendingPathComponent("pk-admission-" + UUID().uuidString)),
            workspaceCreator: MockWorkspaceCreator()
        )
        let toolRouter = ToolRouter(
            timelineManager: timelineManager,
            runtimeRepository: repository
        )
        let engine = TurnEngine(
            dependencies: .init(
                timelineManager: timelineManager,
                agentStore: backing,
                requestOriginStore: backing,
                runtimeRepository: repository,
                llmService: MockLLMService(),
                toolRouter: toolRouter
            )
        )
        let timelineID = UUID()
        try await repository.saveTimeline(TimelineRecord(id: timelineID, attachedAgentID: attachedAgent?.id))
        if let attachedAgent {
            try await backing.saveAgent(attachedAgent)
        }
        try await timelineManager.hydrateTimeline(id: timelineID)
        return AdmissionHarness(
            engine: engine,
            repository: repository,
            timelineID: timelineID
        )
    }

}

private struct AdmissionHarness {
    let engine: TurnEngine
    let repository: InMemoryTimelineRuntimeRepository
    let timelineID: UUID
}

private struct ReservedCallTool: PKContracts.PKTool, Sendable {
    let callName = "call_tool"
    let name = "Reserved call tool"
    let toolDescription = "Test-only reserved tool"
    let requiresPermission = false
    let parametersSchema = makeEmptyObjectSchema()

    func canExecute() async -> Bool { true }

    func execute(parameters _: [String: AnyCodable]) async throws -> ToolResult {
        .success("unused")
    }
}
