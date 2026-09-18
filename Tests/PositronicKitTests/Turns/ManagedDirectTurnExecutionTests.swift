import Foundation
import PKContracts
import PKTestSupport
@testable import PositronicKit
import Testing

@Suite("Managed and direct Turn execution", .tags(.integration))
struct ManagedDirectTurnExecutionTests {
    @Test("managed admission captures the attached Agent and assistant provenance")
    func managedTurnCapturesAgent() async throws {
        let llm = MockLLMService()
        llm.mockClient.nextResponse = "managed reply"
        let kit = PKRuntime(languageModel: llm)
        let timeline = try await kit.timelines.create(title: "Managed")
        let agent = try await kit.agents.create(name: "Managed Agent", description: "test")
        try await kit.agents.attach(agent.id, to: timeline.id)

        let turn = try await timeline.startTurn("hello")
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
        let messages = try await repository.fetchMessages(for: timeline.id)
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
        let kit = PKRuntime(languageModel: llm)
        let timeline = try await kit.timelines.create(title: "Admission failure")

        let turn = try await timeline.startDirectTurn(
            "must be durable first",
            context: DirectTurnContext(systemInstructions: "", contributor: .host)
        )
        _ = await turn.events().collect()

        let repository = kit.runtimeRepository
        let record = try #require(try await repository.fetchTurn(id: turn.id))
        let messages = try await repository.fetchMessages(for: timeline.id)
        #expect(record.outcome != nil)
        #expect(messages.first?.role == "user")
        #expect(messages.first?.content == "must be durable first")
        #expect(llm.mockClient.generationCaptureHistory.count == 1)
    }

    @Test("admitted input is not duplicated in the first provider prompt")
    func admittedInputAppearsOnceInProviderPrompt() async throws {
        let llm = MockLLMService()
        llm.mockClient.nextResponse = "reply"
        let kit = PKRuntime(languageModel: llm)
        let timeline = try await kit.timelines.create(title: "Single input")

        let turn = try await timeline.startDirectTurn(
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
        let kit = PKRuntime(languageModel: llm)
        let timeline = try await kit.timelines.create(title: "Direct")

        let turn = try await timeline.startDirectTurn(
            "hello",
            context: DirectTurnContext(systemInstructions: "", contributor: .host)
        )
        _ = await turn.events().collect()

        #expect(try await turn.outcome() == .completed)
        let repository = kit.runtimeRepository
        let messages = try await repository.fetchMessages(for: timeline.id)
        #expect(messages.last?.executionKind == .direct)
        #expect(messages.last?.agentID == nil)
    }

    @Test("direct Turns route call_tool to Timeline-bound Workspaces")
    func directTurnRoutesTimelineWorkspace() async throws {
        let workspace = TestWorkspace()
        let persistence = MockPersistenceService()
        let llm = MockLLMService()
        let repository = InMemoryTimelineRuntimeRepository()
        let kit = PKRuntime(configuration: .init(
            languageModel: llm,
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
        let timeline = try await kit.timelines.create(title: "Direct Workspace")
        let attachedWorkspace = WorkspaceReference(
            uri: WorkspaceURI(host: "remote", path: "/direct"),
            location: .attached,
            tools: [.known("cat")],
            rootPath: workspace.root.path
        )
        try await persistence.saveWorkspace(attachedWorkspace)
        try await persistence.addToolToWorkspace(
            workspaceID: attachedWorkspace.id,
            tool: .known("cat")
        )
        try await kit.timelines.attachWorkspace(attachedWorkspace.id, to: timeline.id)

        llm.mockClient.nextToolCalls = [[MockToolCall(
            id: "direct-workspace-call",
            name: "call_tool",
            arguments: "{\"tool\":\"cat\",\"at\":\"\(attachedWorkspace.id.uuidString)\",\"arguments\":{\"path\":\"README.md\"}}"
        )]]
        llm.mockClient.nextResponse = ""

        let turn = try await timeline.startDirectTurn(
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
        let continuation = try await kit.turnEngine.run(
            TurnRequest(
                timelineID: timeline.id,
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
        let persistedMessages = try await repository.fetchMessages(for: timeline.id)
        #expect(persistedMessages.contains { $0.role == "tool" && $0.toolCallID == "direct-workspace-call" })
        #expect(try await repository.fetchToolResults(turnID: turn.id).isEmpty)
    }

    @Test("managed and direct Turns retain provenance in mixed Timeline history")
    func mixedHistoryPreservesProvenance() async throws {
        let llm = MockLLMService()
        llm.mockClient.nextResponse = "reply"
        let kit = PKRuntime(languageModel: llm)
        let timeline = try await kit.timelines.create(title: "Mixed")

        let direct = try await timeline.startDirectTurn(
            "direct",
            context: DirectTurnContext(systemInstructions: "", contributor: .host)
        )
        _ = await direct.events().collect()
        #expect(try await direct.outcome() == .completed)

        let agent = try await kit.agents.create(name: "Mixed Agent", description: "test")
        try await kit.agents.attach(agent.id, to: timeline.id)
        let managed = try await timeline.startTurn("managed")
        _ = await managed.events().collect()

        let repository = kit.runtimeRepository
        let assistantKinds = try await repository.fetchMessages(for: timeline.id)
            .filter { $0.role == "assistant" }
            .map(\.executionKind)
        #expect(assistantKinds == [.direct, .agentManaged])
    }

    @Test("managed execution fails before persistence when no Agent is attached")
    func managedTurnRequiresAgent() async throws {
        let kit = PKRuntime(languageModel: MockLLMService())
        let timeline = try await kit.timelines.create(title: "Detached")

        let managedError = await #expect(throws: TurnError.self) {
            _ = try await timeline.startTurn("must not persist")
        }
        if case let .managedExecutionRequiresAttachedAgent(timelineID)? = managedError {
            #expect(timelineID == timeline.id)
        }

        let repository = kit.runtimeRepository
        #expect(try await repository.fetchMessages(for: timeline.id).isEmpty)
    }

    @Test("direct execution is rejected while an Agent is attached")
    func directTurnRequiresDetachedTimeline() async throws {
        let kit = PKRuntime(languageModel: MockLLMService())
        let timeline = try await kit.timelines.create(title: "Attached")
        let agent = try await kit.agents.create(name: "Attached Agent", description: "test")
        try await kit.agents.attach(agent.id, to: timeline.id)

        let directError = await #expect(throws: TurnError.self) {
            _ = try await timeline.startDirectTurn(
                "must not persist",
                context: DirectTurnContext(systemInstructions: "", contributor: .host)
            )
        }
        if case let .directExecutionRequiresDetachedTimeline(timelineID)? = directError {
            #expect(timelineID == timeline.id)
        }
    }

    @Test("a distinct request cannot replace an active Turn")
    func distinctTurnIsBusy() async throws {
        let llm = MockLLMService()
        llm.mockClient.neverFinishingStreamCallIndices = [1]
        let kit = PKRuntime(languageModel: llm)
        let timeline = try await kit.timelines.create(title: "Busy")
        let agent = try await kit.agents.create(name: "Busy Agent", description: "test")
        try await kit.agents.attach(agent.id, to: timeline.id)

        let first = try await timeline.startTurn("first")
        await #expect(throws: TimelineRuntimeRepositoryError.self) {
            _ = try await timeline.startTurn("second")
        }
        await first.cancel()
        _ = await first.events().collect()
    }

    @Test("joiners receive future terminal events and replay the durable outcome")
    func joinedTurnReceivesFutureEvents() async throws {
        let llm = MockLLMService()
        llm.mockClient.neverFinishingStreamCallIndices = [1]
        let kit = PKRuntime(languageModel: llm)
        let timeline = try await kit.timelines.create(title: "Join")
        let agent = try await kit.agents.create(name: "Join Agent", description: "test")
        try await kit.agents.attach(agent.id, to: timeline.id)
        let requestID = UUID()

        let options = TurnOptions(requestID: requestID)
        let first = try await timeline.startTurn("same", options: options)
        while llm.mockClient.neverFinishingStreamStartCount < 1 {
            await Task.yield()
        }
        let joined = try await timeline.startTurn("same", options: options)
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

    /// A `.joined` execution observes a Turn the *first* caller admitted. Walking away from that
    /// observation must not cancel the owner's generation.
    ///
    /// The assertion is deliberately on a *positive* signal — the owner keeps receiving text.
    /// Cancellation is relayed from a detached task, so asserting that the registry entry merely
    /// still exists would race that task and pass even when the Turn is about to be killed.
    @Test("abandoning a joiner's stream leaves the owner's generation running", .timeLimit(.minutes(1)))
    func abandonedJoinerDoesNotCancelOwner() async throws {
        let llm = MockLLMService()
        llm.mockClient.nextChunks = [Array(repeating: "x", count: 200)]
        llm.mockClient.nextStreamWait = 0.05
        let kit = PKRuntime(languageModel: llm)
        let timeline = try await kit.timelines.create(title: "Join")
        let agent = try await kit.agents.create(name: "Join Agent", description: "test")
        try await kit.agents.attach(agent.id, to: timeline.id)

        let options = TurnOptions(requestID: UUID())
        let first = try await timeline.startTurn("same", options: options)
        let joined = try await timeline.startTurn("same", options: options)
        #expect(joined.id == first.id)

        var ownerIterator = first.events().makeAsyncIterator()
        var ownerIsStreaming = false
        while !ownerIsStreaming, let event = await ownerIterator.next() {
            ownerIsStreaming = event.textContent != nil
        }
        #expect(ownerIsStreaming, "Owner should be streaming before the joiner attaches")

        let (observed, observedContinuation) = AsyncStream<Void>.makeStream()
        let abandoning = Task {
            defer { observedContinuation.finish() }
            for await event in joined.events() where event.textContent != nil {
                observedContinuation.yield(())
            }
        }
        var observedIterator = observed.makeAsyncIterator()
        #expect(await observedIterator.next() != nil, "Joiner should observe the live stream")

        // Cancelling the joiner's consumer terminates its stream as `.cancelled`.
        abandoning.cancel()
        _ = await abandoning.value

        var textAfterAbandon = 0
        var ownerWasCancelled = false
        while textAfterAbandon < 10, let event = await ownerIterator.next() {
            if event.textContent != nil { textAfterAbandon += 1 }
            if case .error(.generationCancelled) = event {
                ownerWasCancelled = true
                break
            }
        }
        #expect(!ownerWasCancelled, "A joiner abandoning its stream must not cancel the owner's Turn")
        #expect(textAfterAbandon == 10, "Owner's generation should keep streaming")

        await first.cancel()
        while await ownerIterator.next() != nil { }
    }

    /// The public `TurnHandle` path must relay consumer cancellation to the Turn, not just the
    /// package-internal engine `run(_:)` path.
    @Test("cancelling the owner's event consumer cancels the Turn", .timeLimit(.minutes(1)))
    func cancellingOwnerConsumerCancelsTurn() async throws {
        let llm = MockLLMService()
        llm.mockClient.nextChunks = [Array(repeating: "x", count: 200)]
        llm.mockClient.nextStreamWait = 0.05
        let kit = PKRuntime(languageModel: llm)
        let timeline = try await kit.timelines.create(title: "Owner")
        let agent = try await kit.agents.create(name: "Owner Agent", description: "test")
        try await kit.agents.attach(agent.id, to: timeline.id)

        let turn = try await timeline.startTurn("hello")

        let (observed, observedContinuation) = AsyncStream<Void>.makeStream()
        let consumer = Task {
            defer { observedContinuation.finish() }
            for await event in turn.events() where event.textContent != nil {
                observedContinuation.yield(())
            }
        }
        var observedIterator = observed.makeAsyncIterator()
        #expect(await observedIterator.next() != nil, "Consumer should observe the live stream")

        let activeTask = try #require(await kit.timelineManager.activeTaskCompletion(for: timeline.id))

        // No explicit `cancel()`: dropping the consumer is the only cancellation signal here.
        consumer.cancel()
        _ = await consumer.value
        _ = await activeTask.value

        #expect(await kit.timelineManager.hasActiveTask(for: timeline.id) == false)
        #expect(try await turn.outcome() == .cancelled(reason: "Turn task cancelled."))
    }

    @Test("identical submissions join while the first Turn is preparing")
    func identicalSubmissionsJoinDuringPreparation() async throws {
        let llm = MockLLMService()
        llm.mockClient.nextResponse = "prepared reply"
        let preparation = AdmissionPreparationGate()
        let kit = PKRuntime(configuration: .init(
            languageModel: llm,
            persistence: .inMemory(),
            runtime: .init(customization: RuntimeCustomization(turnContextSource: preparation))
        ))
        let timeline = try await kit.timelines.create(title: "Admission join")
        let requestID = UUID()

        let firstTask = Task {
            try await timeline.startDirectTurn(
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
        let admitted = try await repository.fetchMessages(for: timeline.id)
        #expect(admitted.map(\.content) == ["same request"])
        #expect(llm.mockClient.generationCaptureHistory.isEmpty)

        let joined = try await timeline.startDirectTurn(
            "same request",
            context: DirectTurnContext(systemInstructions: "", contributor: .host),
            options: TurnOptions(requestID: requestID)
        )
        #expect((try await repository.fetchTurn(id: joined.id))?.identity.turnID == joined.id)
        #expect(try await repository.fetchMessages(for: timeline.id).count == 1)
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
        let kit = PKRuntime(languageModel: llm)
        let timeline = try await kit.timelines.create(title: "Replay")
        let requestID = UUID()

        let first = try await timeline.startDirectTurn(
            "same",
            context: DirectTurnContext(systemInstructions: "", contributor: .host),
            options: TurnOptions(requestID: requestID)
        )
        _ = await first.events().collect()

        let replay = try await timeline.startDirectTurn(
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
