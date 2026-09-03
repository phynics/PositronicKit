import Foundation
import PKContracts
import PKTestSupport
import PKUtilities
@testable import PositronicKit
import Testing

@Suite(.serialized)
struct TurnAdmissionSeamTests {
    @Test("managed admission captures authoritative Agent context")
    func managedAdmissionCapturesAuthority() async throws {
        let agent = Agent(name: "Managed", description: "test", privateThreadID: UUID())
        let harness = try await makeHarness(attachedAgent: agent)
        let requestID = UUID()
        let turnID = UUID()
        let result = try await harness.engine.admitTurn(TurnEngine.TurnAdmissionRequest(
            threadID: harness.threadID,
            turnID: turnID,
            requestID: requestID,
            inputMessage: ThreadMessage(
                id: requestID,
                threadID: harness.threadID,
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

    @Test("direct admission captures detached Thread authority without Agent context")
    func directAdmissionCapturesDetachedAuthority() async throws {
        let harness = try await makeHarness()
        let requestID = UUID()
        let turnID = UUID()
        let result = try await harness.engine.admitTurn(TurnEngine.TurnAdmissionRequest(
            threadID: harness.threadID,
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
        let first = try await harness.engine.admitTurn(makeRequest(
            threadID: harness.threadID,
            turnID: firstTurnID,
            requestID: requestID,
            content: "same"
        ))
        let joined = try await harness.engine.admitTurn(makeRequest(
            threadID: harness.threadID,
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
        #expect(try await harness.repository.fetchMessages(for: harness.threadID).count == 1)
    }

    @Test("a terminal repository Turn is replayed, not re-executed, for the same request")
    func terminalRequestReplays() async throws {
        let harness = try await makeHarness()
        let requestID = UUID()
        let turnID = UUID()
        _ = try await harness.engine.admitTurn(makeRequest(
            threadID: harness.threadID,
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

        let replayed = try await harness.engine.admitTurn(makeRequest(
            threadID: harness.threadID,
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
        #expect(try await harness.repository.fetchMessages(for: harness.threadID).count == 1)
    }

    @Test("reserved call_tool validation happens before admission")
    func reservedToolIsRejectedBeforeAdmission() async throws {
        let harness = try await makeHarness()

        await #expect(throws: ToolError.reservedToolName("call_tool")) {
            _ = try await harness.engine.prepareSession(
                TurnExecutionRequest(
                    TurnRequest(
                        threadID: harness.threadID,
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

        #expect(try await harness.repository.fetchMessages(for: harness.threadID).isEmpty)
        #expect(try await harness.repository.fetchActiveTurn(for: harness.threadID) == nil)
    }

    @Test("post-admission preparation failure retains input and records a failed Turn")
    func preparationFailureRetainsAtomicInput() async throws {
        let harness = try await makeHarness()
        let requestID = UUID()
        let turnID = UUID()

        await #expect(throws: Error.self) {
            _ = try await harness.engine.prepareSession(
                TurnExecutionRequest(
                    TurnRequest(
                        threadID: harness.threadID,
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

        let messages = try await harness.repository.fetchMessages(for: harness.threadID)
        #expect(messages.filter { $0.role == "user" }.map(\.content) == ["retained input"])
        let record = try #require(try await harness.repository.fetchTurn(id: turnID))
        #expect(record.outcome == .failed(message: "Turn preparation failed before execution."))
        #expect(try await harness.repository.fetchActiveTurn(for: harness.threadID) == nil)
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
        try await harness.repository.saveMessage(ThreadMessage(
            threadID: harness.threadID,
            role: .assistant,
            content: "",
            toolCalls: String(decoding: calls, as: UTF8.self)
        ))

        await #expect(throws: Error.self) {
            _ = try await harness.engine.prepareSession(
                TurnExecutionRequest(
                    TurnRequest(
                        threadID: harness.threadID,
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
            threadID: harness.threadID,
            runtimeRepository: harness.repository
        )
        #expect(retryable.map(\.toolCallID) == [callID])
        await harness.engine.dependencies.submissionGate.releaseReservations(
            threadID: harness.threadID,
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
        try await harness.repository.saveMessage(ThreadMessage(
            threadID: harness.threadID,
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
                threadID: harness.threadID,
                runtimeRepository: harness.repository
            )
        }

        // If the first output's reservation leaked, this second validate would see it as already
        // reserved and drop it from the pending set, so `retryable` would come back empty.
        let retryable = try await gate.validate(
            [ToolOutputSubmission(toolCallID: goodCallID, output: "result")],
            threadID: harness.threadID,
            runtimeRepository: harness.repository
        )
        #expect(retryable.map(\.toolCallID) == [goodCallID])
        await gate.releaseReservations(threadID: harness.threadID, toolCallIds: [goodCallID])
    }

    /// Regression for D-03(b): a reservation must not strand when the caller is cancelled between
    /// `validate` and `commit`. `withReservation` wraps that window and releases on every exit —
    /// including a cancellation `operation` never itself observes or checks — via
    /// `withTaskCancellationHandler`, not merely a `do`/`catch` around `operation`.
    @Test("withReservation releases its reservation when cancelled before commit")
    func withReservationReleasesOnCancellationBeforeCommit() async throws {
        let harness = try await makeHarness()
        let callID = "cancelled-before-commit"
        let calls = try SerializationUtils.jsonEncoder.encode([
            ToolCall(id: callID, name: "external_tool", arguments: [:]),
        ])
        try await harness.repository.saveMessage(ThreadMessage(
            threadID: harness.threadID,
            role: .assistant,
            content: "",
            toolCalls: String(decoding: calls, as: UTF8.self)
        ))

        let gate = harness.engine.dependencies.submissionGate
        let (enteredOperation, signalEntered) = AsyncStream<Void>.makeStream()
        let (releaseOperation, signalRelease) = AsyncStream<Void>.makeStream()

        let task = Task {
            try await gate.withReservation(
                [ToolOutputSubmission(toolCallID: callID, output: "result")],
                threadID: harness.threadID,
                runtimeRepository: harness.repository
            ) { validated -> Void in
                signalEntered.yield()
                // `operation` never checks cancellation itself, standing in for a caller whose
                // work between reservation and commit doesn't happen to surface a thrown error —
                // exactly the gap a bare `do`/`catch` around `operation` would miss.
                for await _ in releaseOperation {}
                #expect(validated.map(\.toolCallID) == [callID])
            }
        }

        var entered = enteredOperation.makeAsyncIterator()
        _ = await entered.next()
        task.cancel()
        signalRelease.finish()
        _ = try? await task.value

        // The cancellation handler releases from its own detached cleanup Task (see
        // `withReservation`'s doc comment on why `operation` completing isn't itself the release
        // signal), so give it a bounded window to land instead of asserting on the very next
        // scheduler tick.
        var retryable: [ToolOutputSubmission] = []
        for _ in 0 ..< 50 {
            retryable = try await gate.validate(
                [ToolOutputSubmission(toolCallID: callID, output: "result")],
                threadID: harness.threadID,
                runtimeRepository: harness.repository
            )
            if !retryable.isEmpty { break }
            try await Task.sleep(for: .milliseconds(20))
        }

        // If the reservation had leaked, `retryable` stays empty for the whole bounded window
        // because `validate` sees the call ID as already reserved.
        #expect(retryable.map(\.toolCallID) == [callID])
        await gate.releaseReservations(threadID: harness.threadID, toolCallIds: [callID])
    }

    private func makeRequest(
        threadID: UUID,
        turnID: UUID,
        requestID: UUID,
        content: String
    ) -> TurnEngine.TurnAdmissionRequest {
        TurnEngine.TurnAdmissionRequest(
            threadID: threadID,
            turnID: turnID,
            requestID: requestID,
            inputMessage: ThreadMessage(
                id: requestID,
                threadID: threadID,
                role: .user,
                content: content
            ),
            executionKind: .direct,
            agentID: nil,
            callerIntentFingerprint: "same-intent"
        )
    }

    private func makeHarness(attachedAgent: Agent? = nil) async throws -> AdmissionHarness {
        let repository = InMemoryThreadRuntimeRepository()
        let backing = MockPersistenceService()
        let threadManager = ThreadManager(
            stores: .init(
                threadStore: repository,
                messageStore: repository,
                workspaceStore: backing,
                workspaceBindingRepository: repository,
                runtimeRepository: repository,
                toolPersistence: backing
            ),
            workspaceProfile: .hostManaged(root: URL(fileURLWithPath: "/tmp/pk-admission")),
            workspaceCreator: MockWorkspaceCreator()
        )
        let toolRouter = ToolRouter(
            threadManager: threadManager,
            runtimeRepository: repository
        )
        let engine = TurnEngine(
            dependencies: .init(
                threadManager: threadManager,
                agentStore: backing,
                requestOriginStore: backing,
                runtimeRepository: repository,
                llmService: MockLLMService(),
                toolRouter: toolRouter
            )
        )
        let threadID = UUID()
        try await repository.saveThread(Thread(id: threadID, attachedAgentID: attachedAgent?.id))
        if let attachedAgent {
            try await backing.saveAgent(attachedAgent)
        }
        try await threadManager.hydrateThread(id: threadID)
        return AdmissionHarness(
            engine: engine,
            repository: repository,
            threadID: threadID
        )
    }

}

private struct AdmissionHarness {
    let engine: TurnEngine
    let repository: InMemoryThreadRuntimeRepository
    let threadID: UUID
}

private struct ReservedCallTool: PKContracts.Tool, Sendable {
    let callName = "call_tool"
    let name = "Reserved call tool"
    let description = "Test-only reserved tool"
    let requiresPermission = false
    let parametersSchema = makeEmptyObjectSchema()

    func canExecute() async -> Bool { true }

    func execute(parameters _: [String: AnyCodable]) async throws -> ToolResult {
        .success("unused")
    }
}
