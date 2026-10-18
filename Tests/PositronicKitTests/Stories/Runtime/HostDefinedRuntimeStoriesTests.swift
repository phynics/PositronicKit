import Foundation
import JSONSchema
import PKContracts
import PKTestSupport
import PositronicKit
import Testing

@Suite("Host-defined runtime stories", .tags(.integration))
struct HostDefinedRuntimeStoriesTests {
    @Test("a detached Timeline runs host context and request-scoped tools across model rounds")
    func directTurnRunsHostToolsAcrossModelRounds() async throws {
        let model = MockLLMService()
        let usage = LLMTokenUsage(promptTokens: 8, completionTokens: 3, totalTokens: 11)
        model.mockClient.nextRawStreamChunks = [
            [toolCallChunk(id: "lookup-1", name: "host_lookup")],
            [toolCallChunk(id: "lookup-2", name: "host_lookup")],
            [textChunk("The host data is ready.", usage: usage)],
        ]

        let repository = InMemoryTimelineRuntimeRepository()
        let runtime = makeRuntime(model: model, repository: repository)
        let timeline = try await runtime.timelines.create(title: "Host-owned conversation")
        let probe = RequestToolProbe()
        let tool = HostLookupTool(probe: probe)
        let instructions = "Use the caller's host data. Do not invent results."
        let turn = try await timeline.startDirectTurn(
            "Look up the requested value twice.",
            context: DirectTurnContext(systemInstructions: instructions, contributor: .host),
            options: TurnOptions(tools: [tool])
        )

        let events = await turn.events().collect()
        let result = try await turn.result()

        #expect(result.outcome == .completed)
        #expect(result.message?.content == "The host data is ready.")
        #expect(try await turn.outcome() == .completed)
        #expect(await probe.executionCount == 2)
        #expect(model.generationCaptureHistory.count == 3)
        #expect(model.generationCaptureHistory.allSatisfy { capture in
            capture.messages.contains {
                $0.role == .system && $0.content.contains(instructions)
            } && capture.tools?.contains(where: { $0.name == "host_lookup" }) == true
        })
        #expect(events.contains { event in
            if case let .completion(.toolExecution(id, status)) = event,
               case let .success(result) = status
            {
                return id == "lookup-1" && result.output == "host lookup 1"
            }
            return false
        })
        #expect(events.contains { event in
            if case let .completion(.toolExecution(id, status)) = event,
               case let .success(result) = status
            {
                return id == "lookup-2" && result.output == "host lookup 2"
            }
            return false
        })
        let completion = try #require(events.compactMap { event -> LLMResponse? in
            guard case let .completion(.generationCompleted(_, metadata)) = event else { return nil }
            return metadata
        }.last)
        #expect(completion.usage == usage)

        let intents = try await repository.fetchToolIntents(turnID: turn.id)
        let results = try await repository.fetchToolResults(turnID: turn.id)
        #expect(intents.map(\.toolCallID) == ["lookup-1", "lookup-2"])
        #expect(results.map(\.output) == ["host lookup 1", "host lookup 2"])
    }

    @Test("a direct Turn can use a separately bound ordinary Workspace")
    func directTurnUsesOrdinaryWorkspace() async throws {
        let model = MockLLMService()
        let repository = InMemoryTimelineRuntimeRepository()
        let workspaces = InMemoryWorkspacePersistence()
        let workspaceTool = ToolDefinition(
            id: "workspace_lookup",
            name: "workspace_lookup",
            description: "Looks up a value in the catalog Workspace."
        )
        let workspace = WorkspaceReference(
            uri: WorkspaceURI(host: "host", path: "/catalog"),
            location: .runtimeTimeline,
            tools: [.custom(workspaceTool)]
        )
        try await workspaces.saveWorkspace(workspace)

        let runtime = makeRuntime(
            model: model,
            repository: repository,
            workspaces: workspaces,
            workspaceFactory: HostWorkspaceFactory()
        )
        let timeline = try await runtime.timelines.create(title: "Workspace conversation")
        try await runtime.timelines.attachWorkspace(workspace.id, to: timeline.id)
        model.mockClient.nextToolCalls = [[MockToolCall(
            id: "workspace-1",
            name: "call_tool",
            arguments: "{\"tool\":\"workspace_lookup\",\"at\":\"\(workspace.id.uuidString)\",\"arguments\":{}}"
        )]]
        model.mockClient.nextResponses = ["", "Workspace data is ready."]

        let turn = try await timeline.startDirectTurn(
            "Use the bound workspace.",
            context: DirectTurnContext(systemInstructions: "Use workspace data only.")
        )
        let events = await turn.events().collect()

        #expect(try await turn.outcome() == .completed)
        #expect(events.contains { event in
            if case let .completion(.toolExecution(id, status)) = event,
               case let .workspaceSucceeded(result, workspaceID, routing) = status
            {
                return id == "workspace-1"
                    && result.output == "workspace:catalog"
                    && workspaceID == workspace.id
                    && routing == .explicit
            }
            return false
        })
        let intents = try await repository.fetchToolIntents(turnID: turn.id)
        #expect(intents.first?.workspaceID == workspace.id)
        #expect(intents.first?.workspaceRouting == .explicit)
    }

    @Test("a fresh runtime reloads history, replays a request, and continues the Timeline")
    func injectedRepositorySurvivesRuntimeReconstruction() async throws {
        let repository = InMemoryTimelineRuntimeRepository()
        let firstModel = MockLLMService()
        firstModel.mockClient.nextResponse = "First reply"
        let firstRuntime = makeRuntime(model: firstModel, repository: repository)
        let firstTimeline = try await firstRuntime.timelines.create(title: "Reconstructed")
        let requestID = UUID()
        let context = DirectTurnContext(systemInstructions: "Answer with the stored history.")
        let options = TurnOptions(requestID: requestID)
        let firstTurn = try await firstTimeline.startDirectTurn(
            "Remember this value.",
            context: context,
            options: options
        )
        _ = await firstTurn.events().collect()

        let nextModel = MockLLMService()
        nextModel.mockClient.nextResponse = "Second reply"
        let nextRuntime = makeRuntime(model: nextModel, repository: repository)
        let restoredTimeline = nextRuntime.timelines.open(firstTimeline.timelineID)
        let restoredHistory = try await nextRuntime.timelines.messages(for: firstTimeline.timelineID)

        #expect(restoredHistory.map(\.content) == ["Remember this value.", "First reply"])

        let replay = try await restoredTimeline.startDirectTurn(
            "Remember this value.",
            context: context,
            options: options
        )
        let replayEvents = await replay.events().collect()
        #expect(replay.id == firstTurn.id)
        #expect(replayEvents.filter(\.isTerminal).count == 1)
        #expect(nextModel.generationCaptureHistory.isEmpty)

        let continued = try await restoredTimeline.startDirectTurn(
            "Continue from the stored history.",
            context: context
        )
        _ = await continued.events().collect()

        #expect(try await continued.outcome() == .completed)
        #expect(nextModel.generationCaptureHistory.count == 1)
        #expect(try await nextRuntime.timelines.messages(for: firstTimeline.timelineID).map(\.content) == [
            "Remember this value.", "First reply", "Continue from the stored history.", "Second reply",
        ])
    }

    @Test("a reconstructed runtime blocks admission while an external tool intent is unresolved")
    func unresolvedExternalEffectRequiresHostReconciliation() async throws {
        let repository = InMemoryTimelineRuntimeRepository()
        let initialRuntime = makeRuntime(model: MockLLMService(), repository: repository)
        let timeline = try await initialRuntime.timelines.create(title: "External effect recovery")
        let requestID = UUID()
        let admission = try await repository.admitTurn(
            timelineID: timeline.timelineID,
            requestID: requestID,
            callerIntentFingerprint: "external-operation:transfer-1",
            inputMessage: TimelineMessage(
                id: requestID,
                timelineID: timeline.timelineID,
                role: .user,
                content: "Submit the transfer."
            ),
            executionKind: .direct,
            capturedAgentID: nil,
            turnID: UUID(),
            now: Date(timeIntervalSince1970: 100)
        )
        try await repository.recordToolIntent(RuntimeToolIntent(
            turnID: admission.turn.identity.turnID,
            timelineID: timeline.timelineID,
            toolCallID: "transfer-1",
            name: "submit_transfer",
            arguments: "{}",
            modelRoundIndex: 0,
            sideEffects: .externalProcess
        ))
        _ = try await repository.interruptTurn(
            turnID: admission.turn.identity.turnID,
            reason: "The host stopped while the transfer result was unknown.",
            disposition: .quarantined("Reconcile transfer-1 with the payment service."),
            now: Date(timeIntervalSince1970: 101)
        )

        let model = MockLLMService()
        model.mockClient.nextResponse = "Proceed after reconciliation."
        let restoredRuntime = makeRuntime(model: model, repository: repository)
        let restoredTimeline = restoredRuntime.timelines.open(timeline.timelineID)
        let quarantined = try await restoredTimeline.quarantinedTurn()

        #expect(quarantined?.identity.turnID == admission.turn.identity.turnID)
        #expect(quarantined?.isQuarantined == true)
        let blocked = await #expect(throws: TimelineRuntimeRepositoryError.self) {
            _ = try await restoredTimeline.startDirectTurn(
                "Submit the transfer again.",
                context: DirectTurnContext(systemInstructions: "Check host reconciliation first.")
            )
        }
        #expect(blocked == .timelineQuarantined(
            timelineID: timeline.timelineID,
            turnID: admission.turn.identity.turnID
        ))
        #expect(model.generationCaptureHistory.isEmpty)

        _ = try await restoredTimeline.releaseQuarantine(
            turnID: admission.turn.identity.turnID,
            confirmation: QuarantineReleaseConfirmation(
                phrase: QuarantineReleaseConfirmation.requiredPhrase
            )
        )
        let admitted = try await restoredTimeline.startDirectTurn(
            "Continue after the host reconciled the transfer.",
            context: DirectTurnContext(systemInstructions: "Do not submit the transfer again.")
        )
        _ = await admitted.events().collect()

        #expect(try await admitted.outcome() == .completed)
        #expect(model.generationCaptureHistory.count == 1)
    }

    @Test("the host can cancel a direct Turn and read its terminal outcome")
    func hostCanCancelDirectTurn() async throws {
        let model = MockLLMService()
        model.mockClient.neverFinishingStreamCallIndices = [1]
        let repository = InMemoryTimelineRuntimeRepository()
        let runtime = makeRuntime(model: model, repository: repository)
        let timeline = try await runtime.timelines.create(title: "Host cancellation")
        let turn = try await timeline.startDirectTurn(
            "Wait for the host to cancel.",
            context: DirectTurnContext(systemInstructions: "Wait.")
        )

        while model.mockClient.neverFinishingStreamStartCount == 0 {
            await Task.yield()
        }
        await turn.cancel()
        let events = await turn.events().collect()

        #expect(events.contains { event in
            if case .error(.generationCancelled) = event { return true }
            return false
        })
        #expect(try await turn.outcome() == .cancelled(reason: "Turn task cancelled."))
        #expect(try await repository.fetchTurn(id: turn.id)?.outcome == .cancelled(
            reason: "Turn task cancelled."
        ))
    }

    private func makeRuntime(
        model: MockLLMService,
        repository: any TimelineRuntimeRepository,
        workspaces: any WorkspaceStore = InMemoryWorkspacePersistence(),
        workspaceFactory: any WorkspaceFactory = NullWorkspaceCreator()
    ) -> PKRuntime {
        PKRuntime(configuration: .init(
            languageModel: model,
            persistence: .init(runtimeRepository: repository, workspacePersistence: workspaces),
            runtime: .init(workspaceCreator: workspaceFactory)
        ))
    }
}

private actor RequestToolProbe {
    private(set) var executionCount = 0

    func recordExecution() -> Int {
        executionCount += 1
        return executionCount
    }
}

private struct HostLookupTool: PKTool {
    let probe: RequestToolProbe
    let callName = "host_lookup"
    let name = "Host lookup"
    let toolDescription = "Looks up a value in host-owned data."
    let requiresPermission = false
    let sideEffects: ToolSideEffects = .none
    let parametersSchema = makeEmptyObjectSchema()

    func canExecute() async -> Bool { true }

    func execute(parameters _: [String: AnyCodable]) async throws -> ToolResult {
        let call = await probe.recordExecution()
        return .success("host lookup \(call)")
    }
}

private struct HostWorkspaceFactory: WorkspaceFactory {
    func create(from reference: WorkspaceReference) throws -> any WorkspaceProvider {
        HostWorkspaceProvider(reference: reference)
    }
}

private actor HostWorkspaceProvider: WorkspaceToolProvider {
    let reference: WorkspaceReference

    init(reference: WorkspaceReference) {
        self.reference = reference
    }

    func listTools() async throws -> [ToolReference] {
        reference.tools
    }

    func executeTool(id: String, parameters _: [String: AnyCodable]) async throws -> ToolResult {
        guard id == "workspace_lookup" else {
            throw WorkspaceError.toolExecutionNotSupported
        }
        return .success("workspace:catalog")
    }

    var isHealthy: Bool {
        get async { true }
    }
}

private func toolCallChunk(id: String, name: String) -> LLMStreamChunk {
    LLMStreamChunk(
        id: "host-defined-\(id)",
        model: "mock-model",
        choices: [LLMStreamChoice(
            index: 0,
            delta: LLMStreamDelta(
                role: .assistant,
                toolCalls: [LLMToolCallDelta(
                    index: 0,
                    id: id,
                    function: LLMToolCallDeltaFunction(name: name, arguments: "{}")
                )]
            ),
            finishReason: "tool_calls"
        )]
    )
}

private func textChunk(_ content: String, usage: LLMTokenUsage) -> LLMStreamChunk {
    LLMStreamChunk(
        id: "host-defined-final",
        model: "mock-model",
        choices: [LLMStreamChoice(
            index: 0,
            delta: LLMStreamDelta(role: .assistant, content: content),
            finishReason: "stop"
        )],
        usage: usage
    )
}
