import PKContracts
import PKTestSupport
@testable import PositronicKit
import Testing

@Suite("Runtime assembly", .serialized)
struct RuntimeAssemblyTests {
    @Test("default facade uses one cohesive in-memory repository")
    func defaultFacadeUsesCohesiveRepository() async throws {
        let kit = PositronicKit(languageModel: MockLLMService())
        let repository = kit.runtimeRepository

        await expectCohesiveGraph(kit, repository: repository)

        let thread = try await kit.threads.create(title: "Default assembly")
        let managerThread = try #require(await kit.threadManager.thread(id: thread.id))
        #expect(managerThread.id == thread.id)
        #expect(try await repository.fetchThread(id: thread.id) != nil)
    }

    @Test("explicit cohesive repository reaches every Turn durability consumer")
    func explicitRepositoryReachesEveryTurnConsumer() async throws {
        let repository = InMemoryThreadRuntimeRepository()
        let workspaceStore = MockWorkspacePersistence()
        let bindingRepository = InMemoryWorkspaceBindingRepository()
        let model = MockLLMService()
        model.mockClient.nextResponse = "cohesive reply"

        let kit = makeKit(
            model: model,
            workspacePersistence: workspaceStore,
            runtimeRepository: repository,
            workspaceBindingRepository: bindingRepository
        )

        await expectCohesiveGraph(
            kit,
            repository: repository,
            bindingRepository: bindingRepository,
            workspaceStore: workspaceStore
        )

        let thread = try await kit.threads.create(title: "Explicit repository")
        let turn = try await kit.openThread(thread.id).startDirectTurn(
            message: "persist through the repository",
            context: DirectTurnContext(systemInstructions: "", contributor: .host)
        )
        _ = await turn.events().collect()

        #expect(try await turn.outcome() == .completed)
        #expect(try await repository.fetchThread(id: thread.id) != nil)
        #expect(try await repository.fetchMessages(for: thread.id).map(\.content) == [
            "persist through the repository", "cohesive reply",
        ])
    }

    @Test("explicit binding repository takes precedence over cohesive repository bindings")
    func explicitBindingRepositoryTakesPrecedence() async throws {
        let repository = InMemoryThreadRuntimeRepository()
        let bindingRepository = InMemoryWorkspaceBindingRepository()
        let workspaceStore = MockWorkspacePersistence()
        let kit = makeKit(
            model: MockLLMService(),
            workspacePersistence: workspaceStore,
            runtimeRepository: repository,
            workspaceBindingRepository: bindingRepository
        )

        let thread = try await kit.threads.create(title: "Binding precedence")
        let workspace = WorkspaceReference(
            uri: WorkspaceURI(host: "test", path: "/binding-precedence"),
            location: .attached
        )
        try await workspaceStore.saveWorkspace(workspace)
        try await kit.threads.attachWorkspace(workspace.id, to: thread.id)

        #expect(try await bindingRepository.threadID(for: workspace.id) == thread.id)
        #expect(try await repository.threadID(for: workspace.id) == nil)
        let managerBindingRepository = await kit.threadManager.workspaceBindingRepository
        #expect(managerBindingRepository as AnyObject === bindingRepository as AnyObject)
    }

    @Test("cohesive repository supplies binding authority when it conforms to the binding protocol")
    func cohesiveRepositorySuppliesBindingAuthority() async throws {
        let repository = InMemoryThreadRuntimeRepository()
        let workspaceStore = MockWorkspacePersistence()
        let kit = makeKit(
            model: MockLLMService(),
            workspacePersistence: workspaceStore,
            runtimeRepository: repository
        )

        #expect(kit.workspaceBindingRepository as AnyObject === repository as AnyObject)
        let managerBindingRepository = await kit.threadManager.workspaceBindingRepository
        #expect(managerBindingRepository as AnyObject === repository as AnyObject)

        let thread = try await kit.threads.create(title: "Repository binding")
        let workspace = WorkspaceReference(
            uri: WorkspaceURI(host: "test", path: "/repository-binding"),
            location: .attached
        )
        try await workspaceStore.saveWorkspace(workspace)
        try await kit.threads.attachWorkspace(workspace.id, to: thread.id)

        #expect(try await repository.threadID(for: workspace.id) == thread.id)
    }

    @Test("customization roles and subordinate stores reach the assembled Turn graph")
    func customizationRolesAndSubordinateStoresAreAssembled() async throws {
        let repository = InMemoryThreadRuntimeRepository()
        let workspaceStore = MockWorkspacePersistence()
        let toolPersistence = MockToolPersistence()
        let agentStore = InMemoryAgentStore()
        let requestOriginStore = InMemoryRequestOriginStore()
        let agentContextSource = AssemblyAgentContextSource()
        let turnContextSource = AssemblyTurnContextSource()
        let activitySink = AssemblyActivitySink()
        let outcomeSink = AssemblyOutcomeSink()
        let model = MockLLMService()
        model.mockClient.nextResponse = "customized reply"
        let customization = RuntimeCustomization(
            agentContextSource: agentContextSource,
            turnContextSource: turnContextSource,
            agentActivitySink: activitySink,
            turnOutcomeSink: outcomeSink
        )
        let kit = makeFullyPersistentKit(
            model: model,
            workspacePersistence: workspaceStore,
            toolPersistence: toolPersistence,
            agentStore: agentStore,
            requestOriginStore: requestOriginStore,
            runtimeRepository: repository,
            customization: customization
        )

        #expect(kit.turnEngine.dependencies.agentStore as AnyObject === agentStore as AnyObject)
        #expect(kit.turnEngine.dependencies.requestOriginStore as AnyObject === requestOriginStore as AnyObject)
        #expect(kit.turnEngine.dependencies.agentContextSource as AnyObject === agentContextSource as AnyObject)
        if let resolvedTurnContextSource = kit.turnEngine.dependencies.turnContextSource {
            #expect(resolvedTurnContextSource as AnyObject === turnContextSource as AnyObject)
        } else {
            Issue.record("TurnEngine lost the configured TurnContextSource")
        }
        if let resolvedOutcomeSink = kit.turnEngine.dependencies.turnOutcomeSink {
            #expect(resolvedOutcomeSink as AnyObject === outcomeSink as AnyObject)
        } else {
            Issue.record("TurnEngine lost the configured TurnOutcomeSink")
        }
        let managerThreadAuthority = await kit.agentManager.threadAuthorityCoordinator
        let managerAgentAuthority = await kit.agentManager.agentAuthorityCoordinator
        let threadAuthority = await kit.threadManager.threadAuthorityCoordinator
        #expect(managerThreadAuthority === threadAuthority)
        #expect(managerAgentAuthority === kit.agentAuthorityCoordinator)
        let managerAgentStore = await kit.agentManager.agentStore
        let managerThreadStore = await kit.agentManager.threadStore
        let managerMessageStore = await kit.agentManager.messageStore
        let managerWorkspaceStore = await kit.agentManager.workspaceStore
        let managerRuntimeRepository = await kit.agentManager.runtimeRepository
        #expect(managerAgentStore as AnyObject === agentStore as AnyObject)
        #expect(managerThreadStore as AnyObject === repository as AnyObject)
        #expect(managerMessageStore as AnyObject === repository as AnyObject)
        #expect(managerWorkspaceStore as AnyObject === workspaceStore as AnyObject)
        if let managerRuntimeRepository {
            #expect(managerRuntimeRepository as AnyObject === repository as AnyObject)
        } else {
            Issue.record("AgentManager lost the cohesive runtime repository")
        }
        let managerToolPersistence = await kit.threadManager.toolPersistence
        #expect(managerToolPersistence as AnyObject === toolPersistence as AnyObject)
        let agent = try await kit.agents.create(name: "Assembly Agent", description: "custom")
        let primaryWorkspaceID = try #require(agent.primaryWorkspaceID)
        #expect(try await agentStore.fetchAgent(id: agent.id) != nil)
        #expect(try await kit.workspaceCatalog.getWorkspace(id: primaryWorkspaceID, includeTools: false) != nil)

        let thread = try await kit.threads.create(title: "Customization")
        try await kit.agents.attach(agent.id, to: thread.id)
        let turn = try await kit.openThread(thread.id).startTurn(message: "custom context")
        _ = await turn.events().collect()

        #expect(try await turn.outcome() == .completed)
        #expect(await agentContextSource.callCount == 1)
        #expect(await turnContextSource.callCount == 1)
        #expect(await activitySink.waitUntilAtLeastOne())
        let activities = await activitySink.activities
        let outcomes = await outcomeSink.outcomes
        #expect(!activities.isEmpty)
        #expect(outcomes.count == 1)
        #expect(model.mockClient.lastMessages.map(\.content).joined(separator: "\n").contains("assembly=custom"))
    }

    @Test("cohesive durability barriers are visible before provider and tool side effects")
    func cohesiveDurabilityBarriersAreVisible() async throws {
        let repository = InMemoryThreadRuntimeRepository()
        let workspaceStore = MockWorkspacePersistence()
        let toolPersistence = MockToolPersistence()
        let model = MockLLMService()
        model.mockClient.shouldThrowError = true
        let kit = makeKit(
            model: model,
            workspacePersistence: workspaceStore,
            toolPersistence: toolPersistence,
            runtimeRepository: repository,
            workspaceBindingRepository: InMemoryWorkspaceBindingRepository()
        )

        let thread = try await kit.threads.create(title: "Durability barriers")
        let turn = try await kit.openThread(thread.id).startDirectTurn(
            message: "admit before provider",
            context: DirectTurnContext(systemInstructions: "", contributor: .host)
        )
        _ = await turn.events().collect()

        let record = try #require(try await repository.fetchTurn(id: turn.id))
        let notices = try await repository.fetchNotices(turnID: turn.id)
        #expect(record.outcome != nil)
        #expect(notices.first?.kind == "turn-admitted")
        #expect(notices.contains { $0.kind == "model-round-started" })
        #expect(notices.contains { $0.kind == "provider-request-durable" })
        #expect(try await repository.fetchMessages(for: thread.id).first?.content == "admit before provider")
        #expect(model.generationCaptureHistory.count == 1)
    }

    @Test("cohesive repository owns tool intent before deferred workspace execution")
    func cohesiveRepositoryOwnsToolIntentBeforeWorkspaceExecution() async throws {
        let repository = InMemoryThreadRuntimeRepository()
        let bindingRepository = InMemoryWorkspaceBindingRepository()
        let workspaceStore = MockWorkspacePersistence()
        let toolPersistence = MockToolPersistence()
        let workspace = TestWorkspace()
        let model = MockLLMService()
        let kit = makeKit(
            model: model,
            workspacePersistence: workspaceStore,
            toolPersistence: toolPersistence,
            runtimeRepository: repository,
            workspaceBindingRepository: bindingRepository
        )

        let thread = try await kit.threads.create(title: "Tool durability")
        let attachedWorkspace = WorkspaceReference(
            uri: WorkspaceURI(host: "remote", path: "/tool-durability"),
            location: .attached,
            tools: [.known("cat")],
            rootPath: workspace.root.path
        )
        try await workspaceStore.saveWorkspace(attachedWorkspace)
        toolPersistence.upsertWorkspace(attachedWorkspace)
        try await toolPersistence.addToolToWorkspace(
            workspaceId: attachedWorkspace.id,
            tool: .known("cat")
        )
        try await kit.threads.attachWorkspace(attachedWorkspace.id, to: thread.id)

        model.mockClient.nextToolCalls = [[MockToolCall(
            id: "durable-tool-call",
            name: "call_tool",
            arguments: "{\"tool\":\"cat\",\"at\":\"\(attachedWorkspace.id.uuidString)\",\"arguments\":{\"path\":\"README.md\"}}"
        )]]
        let turn = try await kit.openThread(thread.id).startDirectTurn(
            message: "defer this tool",
            context: DirectTurnContext(systemInstructions: "", contributor: .host)
        )
        let events = await turn.events().collect()

        #expect(events.contains { event in
            if case .completion(.deferredForExternalTool) = event { return true }
            return false
        })
        #expect(try await turn.outcome() == .interrupted(reason: "External tool execution deferred."))
        let intents = try await repository.fetchToolIntents(turnID: turn.id)
        #expect(intents.map(\.toolCallID) == ["durable-tool-call"])
        let notices = try await repository.fetchNotices(turnID: turn.id)
        #expect(notices.contains { $0.kind == "tool-intent-durable" })
    }

    @Test("reconfigured views preserve repositories, authorities, PromptJournal state, and live events")
    func reconfiguredViewsPreserveRuntimeState() async throws {
        let repository = InMemoryThreadRuntimeRepository()
        let bindingRepository = InMemoryWorkspaceBindingRepository()
        let workspaceStore = MockWorkspacePersistence()
        let originalModel = MockLLMService()
        originalModel.mockClient.neverFinishingStreamCallIndices = [1]
        let originalKit = makeKit(
            model: originalModel,
            workspacePersistence: workspaceStore,
            runtimeRepository: repository,
            workspaceBindingRepository: bindingRepository
        )

        let replacementModel = MockLLMService()
        let reconfiguredKit = originalKit.reconfigured(languageModel: replacementModel)

        #expect(originalKit.threadManager === reconfiguredKit.threadManager)
        #expect(originalKit.toolRouter as AnyObject !== reconfiguredKit.toolRouter as AnyObject)
        #expect(
            originalKit.turnEngine.dependencies.llmService as AnyObject
                !== reconfiguredKit.turnEngine.dependencies.llmService as AnyObject
        )
        #expect(originalKit.agentAuthorityCoordinator === reconfiguredKit.agentAuthorityCoordinator)
        #expect(originalKit.turnEngine.dependencies.agentAuthorityCoordinator === reconfiguredKit.agentAuthorityCoordinator)
        #expect(originalKit.turnEngine.dependencies.threadAuthorityCoordinator === reconfiguredKit.turnEngine.dependencies.threadAuthorityCoordinator)
        #expect(originalKit.turnEngine.dependencies.eventHub === reconfiguredKit.turnEngine.dependencies.eventHub)
        #expect(originalKit.turnEngine.dependencies.promptHistoryRegistry === reconfiguredKit.turnEngine.dependencies.promptHistoryRegistry)

        let managerRegistry = await originalKit.threadManager.promptHistoryRegistry
        guard let managerRegistry else {
            Issue.record("ThreadManager lost the shared PromptJournal registry")
            return
        }
        #expect(managerRegistry === originalKit.turnEngine.dependencies.promptHistoryRegistry)
        let originalRepository = originalKit.runtimeRepository
        let reconfiguredRepository = reconfiguredKit.runtimeRepository
        #expect(originalRepository as AnyObject === reconfiguredRepository as AnyObject)
        #expect(originalKit.messageStore as AnyObject === reconfiguredKit.messageStore as AnyObject)
        #expect(originalKit.workspaceBindingRepository as AnyObject === reconfiguredKit.workspaceBindingRepository as AnyObject)

        let thread = try await originalKit.threads.create(title: "Reconfigured assembly")
        let requestID = thread.id
        let original = try await originalKit.openThread(thread.id).startDirectTurn(
            message: "same request",
            context: DirectTurnContext(systemInstructions: "", contributor: .host),
            requestID: requestID
        )
        guard await waitForNeverFinishingStreamStart(originalModel) else {
            await original.cancel()
            _ = await original.events().collect()
            Issue.record("The original reconfigured Turn did not start its provider stream")
            return
        }

        let journalBefore = await originalKit.turnEngine.dependencies.promptHistoryRegistry.history(for: thread.id)
        let joined = try await reconfiguredKit.openThread(thread.id).startDirectTurn(
            message: "same request",
            context: DirectTurnContext(systemInstructions: "", contributor: .host),
            requestID: requestID
        )
        let journalAfter = await reconfiguredKit.turnEngine.dependencies.promptHistoryRegistry.history(for: thread.id)
        #expect(journalBefore === journalAfter)
        #expect(joined.id == original.id)

        let eventsTask = Task { await joined.events().collect() }
        await joined.cancel()
        let events = await eventsTask.value
        #expect(events.filter { $0.isTerminal }.count == 1)
        #expect(try await original.outcome() == .cancelled(reason: "Turn task cancelled."))

        replacementModel.mockClient.nextResponse = "replacement reply"
        let replacementTurn = try await reconfiguredKit.openThread(thread.id).startDirectTurn(
            message: "new provider view",
            context: DirectTurnContext(systemInstructions: "", contributor: .host)
        )
        _ = await replacementTurn.events().collect()
        #expect(try await replacementTurn.outcome() == .completed)
        #expect(replacementModel.generationCaptureHistory.count == 1)
    }

    @Test("reconfigured views retain one per-Workspace execution lane")
    func reconfiguredViewsRetainWorkspaceSerialization() async throws {
        let originalKit = PositronicKit(languageModel: MockLLMService())
        let reconfiguredKit = originalKit.reconfigured(languageModel: MockLLMService())
        let workspaceID = (try await originalKit.threads.create(title: "Lane workspace")).id
        let probe = LaneProbe()

        let first = Task {
            try await originalKit.threadManager.withWorkspaceExecution(workspaceID) {
                await probe.enter(1)
                await probe.waitForRelease()
                await probe.leave()
            }
        }
        #expect(await probe.waitUntilEntryCount(1))
        let second = Task {
            await probe.markSecondReady()
            try await reconfiguredKit.threadManager.withWorkspaceExecution(workspaceID) {
                await probe.enter(2)
                await probe.leave()
            }
        }
        #expect(await probe.waitUntilSecondReady())
        try await Task.sleep(for: .milliseconds(10))
        #expect(await probe.order == [1])

        await probe.releaseFirst()
        // Both lane closures are throwing now that the FIFO lane is cancellation-aware, so the
        // task values are throwing too. Neither should actually throw here: nothing cancels
        // these tasks, so a thrown error is a real failure and must surface, not be swallowed.
        try await first.value
        try await second.value
        #expect(await probe.maximumConcurrent == 1)
        #expect(await probe.order == [1, 2])
    }

    private func makeKit(
        model: MockLLMService,
        workspacePersistence: (any WorkspaceStore)? = nil,
        toolPersistence: (any ToolPersistenceProtocol)? = nil,
        agentStore: (any AgentStoreProtocol)? = nil,
        requestOriginStore: (any RequestOriginStoreProtocol)? = nil,
        runtimeRepository: (any ThreadRuntimeRepository)? = nil,
        workspaceBindingRepository: (any WorkspaceBindingRepository)? = nil,
        customization: RuntimeCustomization = .default
    ) -> PositronicKit {
        PositronicKit(configuration: .init(
            provider: .init(languageModel: model),
            persistence: .init(
                runtimeRepository: runtimeRepository ?? InMemoryThreadRuntimeRepository(),
                workspacePersistence: workspacePersistence,
                toolPersistence: toolPersistence,
                agentStore: agentStore,
                requestOriginStore: requestOriginStore,
                workspaceBindingRepository: workspaceBindingRepository
            ),
            runtime: .init(workspaceCreator: MockWorkspaceCreator(), customization: customization)
        ))
    }

    private func makeFullyPersistentKit(
        model: MockLLMService,
        workspacePersistence: any WorkspaceStore,
        toolPersistence: any ToolPersistenceProtocol,
        agentStore: any AgentStoreProtocol,
        requestOriginStore: any RequestOriginStoreProtocol,
        runtimeRepository: any ThreadRuntimeRepository,
        workspaceBindingRepository: (any WorkspaceBindingRepository)? = nil,
        customization: RuntimeCustomization = .default
    ) -> PositronicKit {
        PositronicKit(configuration: .init(
            provider: .init(languageModel: model),
            persistence: .fullyPersistent(
                runtimeRepository: runtimeRepository,
                workspacePersistence: workspacePersistence,
                toolPersistence: toolPersistence,
                agentStore: agentStore,
                requestOriginStore: requestOriginStore,
                workspaceBindingRepository: workspaceBindingRepository
            ),
            runtime: .init(workspaceCreator: MockWorkspaceCreator(), customization: customization)
        ))
    }

    private func waitForNeverFinishingStreamStart(_ model: MockLLMService) async -> Bool {
        for _ in 0..<100 {
            if model.mockClient.neverFinishingStreamStartCount >= 1 { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return false
    }

    private func expectCohesiveGraph(
        _ kit: PositronicKit,
        repository: any ThreadRuntimeRepository,
        bindingRepository: (any WorkspaceBindingRepository)? = nil,
        workspaceStore: (any WorkspaceStore)? = nil
    ) async {
        #expect(kit.runtimeRepository as AnyObject === repository as AnyObject)
        #expect(kit.messageStore as AnyObject === repository as AnyObject)
        #expect(kit.threadPersistence as AnyObject === repository as AnyObject)
        #expect(kit.turnEngine.dependencies.runtimeRepository as AnyObject === repository as AnyObject)
        #expect(kit.turnEngine.dependencies.threadManager === kit.threadManager)
        #expect(kit.turnEngine.dependencies.toolRouter === kit.toolRouter)

        let managerMessageStore = await kit.threadManager.messageStore
        let managerThreadStore = await kit.threadManager.threadStore
        let managerRepository = await kit.threadManager.runtimeRepository
        #expect(managerMessageStore as AnyObject === repository as AnyObject)
        #expect(managerThreadStore as AnyObject === repository as AnyObject)
        #expect(managerRepository as AnyObject === repository as AnyObject)

        if let bindingRepository {
            #expect(kit.workspaceBindingRepository as AnyObject === bindingRepository as AnyObject)
        }
        if let workspaceStore {
            #expect(kit.workspacePersistence as AnyObject === workspaceStore as AnyObject)
            let managerWorkspaceStore = await kit.threadManager.workspaceStore
            #expect(managerWorkspaceStore as AnyObject === workspaceStore as AnyObject)
        }

        let managerBindingRepository = await kit.threadManager.workspaceBindingRepository
        let expectedBindingRepository = bindingRepository ?? kit.workspaceBindingRepository
        #expect(managerBindingRepository as AnyObject === expectedBindingRepository as AnyObject)
    }

}

private actor LaneProbe {
    private var active = 0
    private(set) var maximumConcurrent = 0
    private(set) var order: [Int] = []
    private var secondReady = false
    private var released = false

    func enter(_ value: Int) {
        active += 1
        maximumConcurrent = max(maximumConcurrent, active)
        order.append(value)
    }

    func leave() {
        active -= 1
    }

    func waitForRelease() async {
        while !released {
            await Task.yield()
        }
    }

    func releaseFirst() {
        released = true
    }

    func markSecondReady() {
        secondReady = true
    }

    func waitUntilSecondReady() async -> Bool {
        for _ in 0..<100 {
            if secondReady { return true }
            await Task.yield()
        }
        return false
    }

    func waitUntilEntryCount(_ count: Int) async -> Bool {
        for _ in 0..<100 {
            if order.count >= count { return true }
            await Task.yield()
        }
        return false
    }
}

private actor AssemblyAgentContextSource: AgentContextSource {
    private(set) var callCount = 0

    func snapshot(for agent: Agent, thread _: Thread) async throws -> AgentContextSnapshot {
        callCount += 1
        return AgentContextSnapshot(agent: agent, instructions: "assembly agent context")
    }
}

private actor AssemblyTurnContextSource: TurnContextSource {
    private(set) var callCount = 0

    func contributions(for _: TurnContextRequest) async throws -> [TurnContextContribution] {
        callCount += 1
        return [try TurnContextContribution(namespace: "host", key: "assembly", text: "assembly=custom")]
    }
}

private actor AssemblyActivitySink: AgentActivitySink {
    private(set) var activities: [AgentActivity] = []

    func record(_ activity: AgentActivity) async throws {
        activities.append(activity)
    }

    func waitUntilAtLeastOne() async -> Bool {
        for _ in 0..<100 {
            if !activities.isEmpty { return true }
            await Task.yield()
        }
        return false
    }
}

private actor AssemblyOutcomeSink: TurnOutcomeSink {
    private(set) var outcomes: [TurnOutcomeRecord] = []

    func record(_ outcome: TurnOutcomeRecord) async throws {
        outcomes.append(outcome)
    }
}
