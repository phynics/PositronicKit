import Foundation
import PKContracts
import PKTestSupport
@testable import PositronicKit
import Testing

@Suite("Managed and direct Turn execution")
struct ManagedDirectTurnExecutionTests {
    @Test("managed admission captures the attached Agent and assistant provenance")
    func managedTurnCapturesAgent() async throws {
        let llm = MockLLMService()
        llm.mockClient.nextResponse = "managed reply"
        let kit = PositronicKit(languageModel: llm)
        let thread = try await kit.threads.create(title: "Managed")
        let agent = try await kit.agents.create(name: "Managed Agent", description: "test")
        try await kit.agents.attach(agent.id, to: thread.id)

        let turn = try await thread.startTurn("hello")
        let events = await turn.events().collect()
        let outcome = try await turn.outcome()

        #expect(events.contains { event in
            if case let .completion(.generationCompleted(message, _)) = event {
                return message.content == "managed reply"
            }
            return false
        })
        #expect(outcome == .completed)
        let repository = kit.runtimeRepository
        let messages = try await repository.fetchMessages(for: thread.id)
        #expect(messages.first?.role == "user")
        #expect(messages.last?.executionKind == .agentManaged)
        #expect(messages.last?.agentID == agent.id)
        let record = try #require(try await repository.fetchTurn(id: turn.id))
        #expect(record.terminalMessageID == messages.last?.id)
    }

    @Test("provider work starts only after the input Turn admission is durable")
    func providerFailureRetainsAtomicallyAdmittedInput() async throws {
        let llm = MockLLMService()
        llm.mockClient.shouldThrowError = true
        let kit = PositronicKit(languageModel: llm)
        let thread = try await kit.threads.create(title: "Admission failure")

        let turn = try await thread.startDirectTurn(
            "must be durable first",
            context: DirectTurnContext(systemInstructions: "", contributor: .host)
        )
        _ = await turn.events().collect()

        let repository = kit.runtimeRepository
        let record = try #require(try await repository.fetchTurn(id: turn.id))
        let messages = try await repository.fetchMessages(for: thread.id)
        #expect(record.outcome != nil)
        #expect(messages.first?.role == "user")
        #expect(messages.first?.content == "must be durable first")
        #expect(llm.mockClient.generationCaptureHistory.count == 1)
    }

    @Test("admitted input is not duplicated in the first provider prompt")
    func admittedInputAppearsOnceInProviderPrompt() async throws {
        let llm = MockLLMService()
        llm.mockClient.nextResponse = "reply"
        let kit = PositronicKit(languageModel: llm)
        let thread = try await kit.threads.create(title: "Single input")

        let turn = try await thread.startDirectTurn(
            "one copy",
            context: DirectTurnContext(systemInstructions: "", contributor: .host)
        )
        _ = await turn.events().collect()

        let firstRequest = try #require(llm.mockClient.generationCaptureHistory.first)
        #expect(firstRequest.messages.filter { $0.role == .user }.map(\.content) == ["one copy"])
    }

    @Test("direct admission requires explicit context and preserves direct provenance")
    func directTurnUsesExplicitContext() async throws {
        let llm = MockLLMService()
        llm.mockClient.nextResponse = "direct reply"
        let kit = PositronicKit(languageModel: llm)
        let thread = try await kit.threads.create(title: "Direct")

        let turn = try await thread.startDirectTurn(
            "hello",
            context: DirectTurnContext(systemInstructions: "", contributor: .host)
        )
        _ = await turn.events().collect()

        #expect(try await turn.outcome() == .completed)
        let repository = kit.runtimeRepository
        let messages = try await repository.fetchMessages(for: thread.id)
        #expect(messages.last?.executionKind == .direct)
        #expect(messages.last?.agentID == nil)
    }

    @Test("direct Turns route call_tool to Thread-bound Workspaces")
    func directTurnRoutesThreadWorkspace() async throws {
        let workspace = TestWorkspace()
        let persistence = MockPersistenceService()
        let llm = MockLLMService()
        let repository = InMemoryThreadRuntimeRepository()
        let kit = PositronicKit(configuration: .init(
            provider: .init(languageModel: llm),
            persistence: .init(
                runtimeRepository: repository,
                workspacePersistence: persistence,
                toolPersistence: persistence,
                agentStore: persistence,
                requestOriginStore: persistence,
                workspaceBindingRepository: InMemoryWorkspaceBindingRepository()
            ),
            runtime: .init(
                workspaceProfile: .hostManaged(root: workspace.root),
                workspaceCreator: MockWorkspaceCreator()
            )
        ))
        let thread = try await kit.threads.create(title: "Direct Workspace")
        let attachedWorkspace = WorkspaceReference(
            uri: WorkspaceURI(host: "remote", path: "/direct"),
            location: .attached,
            tools: [.known("cat")],
            rootPath: workspace.root.path
        )
        try await persistence.saveWorkspace(attachedWorkspace)
        try await persistence.addToolToWorkspace(
            workspaceId: attachedWorkspace.id,
            tool: .known("cat")
        )
        try await kit.threads.attachWorkspace(attachedWorkspace.id, to: thread.id)

        llm.mockClient.nextToolCalls = [[MockToolCall(
            id: "direct-workspace-call",
            name: "call_tool",
            arguments: "{\"tool\":\"cat\",\"at\":\"\(attachedWorkspace.id.uuidString)\",\"arguments\":{\"path\":\"README.md\"}}"
        )]]
        llm.mockClient.nextResponse = ""

        let turn = try await thread.startDirectTurn(
            "Use the attached workspace",
            context: DirectTurnContext(systemInstructions: "", contributor: .host)
        )
        let events = await turn.events().collect()

        #expect(events.contains { event in
            if case .completion(.deferredForExternalTool) = event { return true }
            return false
        })
        #expect(try await turn.outcome() == .interrupted(reason: "External tool execution deferred."))

        let intents = try await repository.fetchToolIntents(turnID: turn.id)
        #expect(intents.first?.workspaceID == attachedWorkspace.id)
        #expect(intents.first?.workspaceRouting == .explicit)
        #expect(intents.first?.name == "call_tool")
        #expect(llm.mockClient.lastTools?.contains(where: { $0.name == "call_tool" }) == true)

        // External continuation is intentionally message-only: the interrupted source Turn keeps
        // its intent, while the submitted output is appended through the same cohesive repository.
        llm.mockClient.nextToolCalls = []
        llm.mockClient.nextResponse = "External result processed"
        let continuation = try await kit.run(
            TurnRequest(
                threadID: thread.id,
                message: "",
                toolOutputs: [ToolOutputSubmission(
                    toolCallID: "direct-workspace-call",
                    output: "host result"
                )],
                systemInstructions: ""
            )
        )
        let continuationEvents = try await continuation.collect()
        #expect(continuationEvents.contains { event in
            if case .completion(.generationCompleted) = event { return true }
            return false
        })
        let persistedMessages = try await repository.fetchMessages(for: thread.id)
        #expect(persistedMessages.contains { $0.role == "tool" && $0.toolCallID == "direct-workspace-call" })
        #expect(try await repository.fetchToolResults(turnID: turn.id).isEmpty)
    }

    @Test("managed and direct Turns retain provenance in mixed Thread history")
    func mixedHistoryPreservesProvenance() async throws {
        let llm = MockLLMService()
        llm.mockClient.nextResponse = "reply"
        let kit = PositronicKit(languageModel: llm)
        let thread = try await kit.threads.create(title: "Mixed")

        let direct = try await thread.startDirectTurn(
            "direct",
            context: DirectTurnContext(systemInstructions: "", contributor: .host)
        )
        _ = await direct.events().collect()
        #expect(try await direct.outcome() == .completed)

        let agent = try await kit.agents.create(name: "Mixed Agent", description: "test")
        try await kit.agents.attach(agent.id, to: thread.id)
        let managed = try await thread.startTurn("managed")
        _ = await managed.events().collect()

        let repository = kit.runtimeRepository
        let assistantKinds = try await repository.fetchMessages(for: thread.id)
            .filter { $0.role == "assistant" }
            .map(\.executionKind)
        #expect(assistantKinds == [.direct, .agentManaged])
    }

    @Test("managed execution fails before persistence when no Agent is attached")
    func managedTurnRequiresAgent() async throws {
        let kit = PositronicKit(languageModel: MockLLMService())
        let thread = try await kit.threads.create(title: "Detached")

        let managedError = await #expect(throws: TurnError.self) {
            _ = try await thread.startTurn("must not persist")
        }
        if case let .managedExecutionRequiresAttachedAgent(threadID)? = managedError {
            #expect(threadID == thread.id)
        }

        let repository = kit.runtimeRepository
        #expect(try await repository.fetchMessages(for: thread.id).isEmpty)
    }

    @Test("direct execution is rejected while an Agent is attached")
    func directTurnRequiresDetachedThread() async throws {
        let kit = PositronicKit(languageModel: MockLLMService())
        let thread = try await kit.threads.create(title: "Attached")
        let agent = try await kit.agents.create(name: "Attached Agent", description: "test")
        try await kit.agents.attach(agent.id, to: thread.id)

        let directError = await #expect(throws: TurnError.self) {
            _ = try await thread.startDirectTurn(
                "must not persist",
                context: DirectTurnContext(systemInstructions: "", contributor: .host)
            )
        }
        if case let .directExecutionRequiresDetachedThread(threadID)? = directError {
            #expect(threadID == thread.id)
        }
    }

    @Test("a distinct request cannot replace an active Turn")
    func distinctTurnIsBusy() async throws {
        let llm = MockLLMService()
        llm.mockClient.neverFinishingStreamCallIndices = [1]
        let kit = PositronicKit(languageModel: llm)
        let thread = try await kit.threads.create(title: "Busy")
        let agent = try await kit.agents.create(name: "Busy Agent", description: "test")
        try await kit.agents.attach(agent.id, to: thread.id)

        let first = try await thread.startTurn("first")
        await #expect(throws: ThreadRuntimeRepositoryError.self) {
            _ = try await thread.startTurn("second")
        }
        await first.cancel()
        _ = await first.events().collect()
    }

    @Test("joiners receive future terminal events and replay the durable outcome")
    func joinedTurnReceivesFutureEvents() async throws {
        let llm = MockLLMService()
        llm.mockClient.neverFinishingStreamCallIndices = [1]
        let kit = PositronicKit(languageModel: llm)
        let thread = try await kit.threads.create(title: "Join")
        let agent = try await kit.agents.create(name: "Join Agent", description: "test")
        try await kit.agents.attach(agent.id, to: thread.id)
        let requestID = UUID()

        let options = TurnOptions(requestID: requestID)
        let first = try await thread.startTurn("same", options: options)
        while llm.mockClient.neverFinishingStreamStartCount < 1 {
            await Task.yield()
        }
        let joined = try await thread.startTurn("same", options: options)
        #expect(joined.id == first.id)
        let repository = kit.runtimeRepository
        let admitted = try #require(try await repository.fetchTurn(id: first.id))
        #expect(admitted.outcome == nil)
        await first.cancel()

        let events = await joined.events().collect()
        #expect(events.filter(\.isTerminal).count == 1)
        #expect(events.contains { event in
            if case .error(.generationCancelled) = event { return true }
            return false
        })
        let outcome = try await joined.outcome()
        #expect(outcome == .cancelled(reason: "Turn task cancelled."))
    }

    @Test("identical submissions join while the first Turn is preparing")
    func identicalSubmissionsJoinDuringPreparation() async throws {
        let llm = MockLLMService()
        llm.mockClient.nextResponse = "prepared reply"
        let preparation = AdmissionPreparationGate()
        let kit = PositronicKit(configuration: .init(
            provider: .init(languageModel: llm),
            persistence: .inMemory(),
            runtime: .init(customization: RuntimeCustomization(turnContextSource: preparation))
        ))
        let thread = try await kit.threads.create(title: "Admission join")
        let requestID = UUID()

        let firstTask = Task {
            try await thread.startDirectTurn(
                "same request",
                context: DirectTurnContext(systemInstructions: "", contributor: .host),
                options: TurnOptions(requestID: requestID)
            )
        }
        guard await preparation.waitUntilEntered() else {
            await preparation.release()
            _ = try? await firstTask.value
            Issue.record("The first Turn did not reach preparation.")
            return
        }

        let repository = kit.runtimeRepository
        let admitted = try await repository.fetchMessages(for: thread.id)
        #expect(admitted.map(\.content) == ["same request"])
        #expect(llm.mockClient.generationCaptureHistory.isEmpty)

        let joined = try await thread.startDirectTurn(
            "same request",
            context: DirectTurnContext(systemInstructions: "", contributor: .host),
            options: TurnOptions(requestID: requestID)
        )
        #expect((try await repository.fetchTurn(id: joined.id))?.identity.turnID == joined.id)
        #expect(try await repository.fetchMessages(for: thread.id).count == 1)
        #expect(llm.mockClient.generationCaptureHistory.isEmpty)

        await preparation.release()
        let first = try await firstTask.value
        _ = await first.events().collect()

        #expect(joined.id == first.id)
        #expect(llm.mockClient.generationCaptureHistory.count == 1)
        #expect(try await first.outcome() == .completed)
    }

    @Test("a completed request replays one durable terminal event")
    func completedTurnReplaysOneTerminal() async throws {
        let llm = MockLLMService()
        llm.mockClient.nextResponse = "replayed reply"
        let kit = PositronicKit(languageModel: llm)
        let thread = try await kit.threads.create(title: "Replay")
        let requestID = UUID()

        let first = try await thread.startDirectTurn(
            "same",
            context: DirectTurnContext(systemInstructions: "", contributor: .host),
            options: TurnOptions(requestID: requestID)
        )
        _ = await first.events().collect()

        let replay = try await thread.startDirectTurn(
            "same",
            context: DirectTurnContext(systemInstructions: "", contributor: .host),
            options: TurnOptions(requestID: requestID)
        )
        let events = await replay.events().collect()

        #expect(events.filter(\.isTerminal).count == 1)
        #expect(events.contains { event in
            if case let .completion(.generationCompleted(message, _)) = event {
                return message.content == "replayed reply"
            }
            return false
        })
    }
}

private actor AdmissionPreparationGate: TurnContextSource {
    private var entered = false
    private var released = false

    func contributions(for _: TurnContextRequest) async throws -> [TurnContextContribution] {
        entered = true
        while !released {
            await Task.yield()
        }
        return []
    }

    func waitUntilEntered() async -> Bool {
        for _ in 0..<100 {
            if entered { return true }
            await Task.yield()
        }
        return false
    }

    func release() {
        released = true
    }
}
