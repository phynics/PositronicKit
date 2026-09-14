import struct Foundation.Date
import class Foundation.FileManager
import struct Foundation.UUID
import PKContracts
import PKTestSupport
@testable import PositronicKit
import Testing

@Suite("Typed Agent context and lifecycle", .tags(.integration))
struct AgentContextLifecycleTests {
    @Test("managed admission captures typed Agent context")
    func capturesTypedContext() async throws {
        let source = RecordingAgentContextSource()
        let llm = MockLLMService()
        llm.mockClient.nextResponse = "context reply"
        let kit = PKRuntime(configuration: .init(
            languageModel: llm,
            persistence: .inMemory(),
            runtime: .init(customization: .init(agentContextSource: source))
        ))
        let timeline = try await kit.timelines.create(title: "Context")
        let agent = try await kit.agents.create(name: "Context Agent", description: "typed")
        try await kit.agents.attach(agent.id, to: timeline.id)

        let turn = try await timeline.startTurn("hello")
        _ = await turn.events().collect()

        #expect(await source.callCount == 1)
        #expect(await source.lastSnapshot?.identity.agentID == agent.id)
        #expect(await source.lastSnapshot?.instructions == "Authoritative instructions")
    }

    @Test("Agent context failure aborts managed preparation before persistence")
    func contextFailureAbortsPreparation() async throws {
        let source = FailingAgentContextSource()
        let kit = PKRuntime(configuration: .init(
            languageModel: MockLLMService(),
            persistence: .inMemory(),
            runtime: .init(customization: .init(agentContextSource: source))
        ))
        let timeline = try await kit.timelines.create(title: "Context failure")
        let agent = try await kit.agents.create(name: "Failing Agent", description: "typed")
        try await kit.agents.attach(agent.id, to: timeline.id)

        await #expect(throws: ContextSourceFailure.self) {
            _ = try await timeline.startTurn("must not persist")
        }

        let repository = kit.runtimeRepository
        #expect(try await repository.fetchMessages(for: timeline.id).isEmpty)
    }

    @Test("retirement drains ordinary attachments and archives the primary Timeline")
    func retirementDrainsAndArchives() async throws {
        let kit = PKRuntime(languageModel: MockLLMService())
        let timeline = try await kit.timelines.create(title: "Ordinary")
        let agent = try await kit.agents.create(name: "Retiring Agent", description: "drain")
        try await kit.agents.attach(agent.id, to: timeline.id)

        try await kit.agents.retire(agent.id)

        let retired = try #require(await kit.agents.get(agent.id))
        #expect(retired.lifecycle == .retired)
        #expect(try await kit.timelines.get(timeline.id)?.attachedAgentID == nil)
        #expect(try await kit.timelines.get(agent.privateTimelineID)?.isArchived == true)

        let retirementError = await #expect(throws: AgentError.self) {
            try await kit.agents.attach(agent.id, to: timeline.id)
        }
        if case let .agentRetired(agentID)? = retirementError {
            #expect(agentID == agent.id)
        }

        try await kit.agents.purge(agent.id)
        #expect(try await kit.agents.get(agent.id) == nil)
    }

    @Test("Agent updates wait behind managed context capture")
    func updateWaitsBehindAdmissionSnapshot() async throws {
        let source = GatedAgentContextSource()
        let llm = MockLLMService()
        llm.mockClient.nextResponse = "gated reply"
        let kit = PKRuntime(configuration: .init(
            languageModel: llm,
            persistence: .inMemory(),
            runtime: .init(customization: .init(agentContextSource: source))
        ))
        let timeline = try await kit.timelines.create(title: "Gated")
        let agent = try await kit.agents.create(name: "Before", description: "initial")
        try await kit.agents.attach(agent.id, to: timeline.id)

        let turnTask = Task { try await timeline.startTurn("hello") }
        await source.waitUntilEntered()

        var changed = agent
        changed.name = "After"
        changed.description = "updated"
        let updateTask = Task { try await kit.agents.update(changed) }
        try await Task.sleep(for: .milliseconds(50))
        #expect(try await kit.agents.get(agent.id)?.name == "Before")

        await source.release()
        let turn = try await turnTask.value
        _ = await turn.events().collect()
        try await updateTask.value
        #expect(try await kit.agents.get(agent.id)?.name == "After")
        #expect(await source.snapshotNames == ["Before"])
    }

    @Test("retirement waits for an active Agent primary Timeline Turn")
    func retirementDrainsPrimaryTimeline() async throws {
        let kit = PKRuntime(languageModel: MockLLMService())
        let agent = try await kit.agents.create(name: "Primary Drain", description: "drain")
        let repository = kit.runtimeRepository
        let admission = try await repository.admitTurn(
            timelineID: agent.privateTimelineID,
            requestID: UUID(),
            callerIntentFingerprint: "primary-drain"
        )

        let retirement = Task { try await kit.agents.retire(agent.id) }
        for _ in 0..<100 {
            if try await kit.agents.get(agent.id)?.lifecycle == .retiring { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(try await kit.agents.get(agent.id)?.lifecycle == .retiring)
        #expect(try await kit.timelines.get(agent.privateTimelineID)?.isArchived == false)

        _ = try await repository.cancelTurn(
            turnID: admission.turn.identity.turnID,
            reason: "test drain",
            now: Date()
        )
        try await retirement.value
        #expect(try await kit.timelines.get(agent.privateTimelineID)?.isArchived == true)
    }

    @Test("managed preparation rejects a source identity mismatch")
    func rejectsIdentityMismatch() async throws {
        let source = WrongIdentityAgentContextSource()
        let kit = PKRuntime(configuration: .init(
            languageModel: MockLLMService(),
            persistence: .inMemory(),
            runtime: .init(customization: .init(agentContextSource: source))
        ))
        let timeline = try await kit.timelines.create(title: "Mismatch")
        let agent = try await kit.agents.create(name: "Mismatch Agent", description: "typed")
        try await kit.agents.attach(agent.id, to: timeline.id)

        await #expect(throws: AgentContextError.identityMismatch(expected: agent.id, actual: source.otherID)) {
            _ = try await timeline.startTurn("must fail")
        }
    }

    @Test("default Agent context loads SOUL and refreshes a discoverable Notes catalog")
    func defaultContextCatalog() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Notes"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "# Agent identity\nBe concise.".write(to: root.appendingPathComponent("SOUL.md"), atomically: true, encoding: .utf8)
        try "---\ndescription: Durable preferences\n---\n# Preferences\n".write(
            to: root.appendingPathComponent("Notes/preferences.md"), atomically: true, encoding: .utf8
        )

        let agentID = UUID()
        let workspaceID = UUID()
        let store = InMemoryWorkspacePersistence()
        try await store.saveWorkspace(WorkspaceReference(
            id: workspaceID,
            uri: .agentWorkspace(agentID),
            location: .runtime,
            rootPath: root.path
        ))
        let source = DefaultAgentContextSource(workspaceStore: store)
        let agent = Agent(id: agentID, name: "Catalog", description: "test", primaryWorkspaceID: workspaceID, privateTimelineID: UUID())
        let timeline = TimelineRecord()

        let first = try await source.snapshot(for: agent, timeline: timeline)
        #expect(first.instructions.contains("Agent identity"))
        #expect(first.memories.isEmpty)
        #expect(first.resources == [AgentContextResource(path: "Notes/preferences.md", description: "Durable preferences")])
        #expect(!first.diagnostics.contains(where: { $0.operation == "readSoul" }))

        try "# New note".write(to: root.appendingPathComponent("Notes/new.md"), atomically: true, encoding: .utf8)
        let refreshed = try await source.snapshot(for: agent, timeline: timeline)
        #expect(refreshed.resources.count == 2)
    }
}

private enum ContextSourceFailure: Error, Equatable {
    case unavailable
}

private actor RecordingAgentContextSource: AgentContextSource {
    private(set) var callCount = 0
    private(set) var lastSnapshot: AgentContextSnapshot?

    func snapshot(for agent: Agent, timeline _: TimelineRecord) async throws -> AgentContextSnapshot {
        callCount += 1
        let snapshot = AgentContextSnapshot(agent: agent, instructions: "Authoritative instructions")
        lastSnapshot = snapshot
        return snapshot
    }
}

private struct FailingAgentContextSource: AgentContextSource {
    func snapshot(for _: Agent, timeline _: TimelineRecord) async throws -> AgentContextSnapshot {
        throw ContextSourceFailure.unavailable
    }
}

private actor GatedAgentContextSource: AgentContextSource {
    private var entered = false
    private var released = false
    private(set) var snapshotNames: [String] = []

    func snapshot(for agent: Agent, timeline _: TimelineRecord) async throws -> AgentContextSnapshot {
        entered = true
        while !released {
            await Task.yield()
        }
        snapshotNames.append(agent.name)
        return AgentContextSnapshot(agent: agent, instructions: agent.description)
    }

    func waitUntilEntered() async {
        while !entered {
            await Task.yield()
        }
    }

    func release() {
        released = true
    }
}

private struct WrongIdentityAgentContextSource: AgentContextSource {
    let otherID = UUID()

    func snapshot(for agent: Agent, timeline _: TimelineRecord) async throws -> AgentContextSnapshot {
        AgentContextSnapshot(
            identity: AgentContextIdentity(
                agentID: otherID,
                name: agent.name,
                description: agent.description
            )
        )
    }
}
