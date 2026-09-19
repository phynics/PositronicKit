import Foundation
import PKContracts
import PKTestSupport
import PositronicKit
import Testing

@Suite("Facade capability values", .tags(.unit))
struct CapabilityValuesTests {
    @Test("Timelines capability creates and reopens a stateful handle")
    func timelineCapabilityOwnsHandleLifecycle() async throws {
        let kit = PKRuntime(languageModel: MockLLMService())

        let handle = try await kit.timelines.create(title: "Capability Timeline")
        let reopened = kit.timelines.open(handle.id)

        #expect(reopened.id == handle.id)
        #expect(try await kit.timelines.get(handle.id)?.title == "Capability Timeline")
    }

    @Test("Agents capability attaches an identity to a Timeline")
    func agentCapabilityOwnsAttachment() async throws {
        let kit = PKRuntime(languageModel: MockLLMService())
        let timeline = try await kit.timelines.create(title: "Managed Timeline")
        let agent = try await kit.agents.create(
            name: "Capability Agent",
            description: "Exercises the capability surface."
        )

        try await kit.agents.attach(agent.id, to: timeline.id)
        let attachedTimelines = try await kit.agents.timelines(attachedTo: agent.id)

        #expect(Set(attachedTimelines.map(\.id)) == [timeline.id, agent.privateTimelineID])
    }

    @Test("Timelines capability creates an ordinary Timeline attached to an existing Agent")
    func createsAttachedTimeline() async throws {
        let llm = MockLLMService()
        llm.mockClient.nextResponse = "ready"
        let kit = PKRuntime(languageModel: llm)
        let agent = try await kit.agents.create(
            name: "Managed Capability Agent",
            description: "Owns the new ordinary Timeline."
        )

        let timeline = try await kit.timelines.create(
            title: "Research",
            attaching: agent.id
        )

        #expect(try await kit.timelines.get(timeline.id)?.attachedAgentID == agent.id)
        let turn = try await timeline.startTurn("Start immediately")
        _ = await turn.events().collect()
        #expect(try await turn.outcome() == .completed)
    }

    @Test("Timelines capability reads direct Turn history oldest first")
    func timelineCapabilityReadsDirectTurnHistory() async throws {
        let llm = MockLLMService()
        llm.mockClient.nextResponse = "assistant reply"
        let kit = PKRuntime(languageModel: llm)
        let timeline = try await kit.timelines.create(title: "Direct history")

        let turn = try await timeline.startDirectTurn(
            "user message",
            context: DirectTurnContext(systemInstructions: "Be concise.")
        )
        _ = await turn.events().collect()

        let messages = try await kit.timelines.messages(for: timeline.id)
        #expect(messages.map(\.content) == ["user message", "assistant reply"])
        #expect(messages.map(\.timestamp) == messages.map(\.timestamp).sorted())
        #expect(try await kit.timelines.messages(for: UUID()).isEmpty)
    }

    @Test("attached Timeline creation rejects a missing Agent before creating a Timeline")
    func rejectsMissingAgentWithoutCreatingTimeline() async throws {
        let kit = PKRuntime(languageModel: MockLLMService())
        let missingAgentID = UUID()

        let error = await #expect(throws: AgentError.self) {
            _ = try await kit.timelines.create(title: "Orphan", attaching: missingAgentID)
        }

        if case let .agentNotFound(actualID)? = error {
            #expect(actualID == missingAgentID)
        }
        #expect(try await kit.timelines.list().isEmpty)
    }

    @Test("attached Timeline creation rejects a retired Agent without creating a Timeline")
    func rejectsRetiredAgentWithoutCreatingTimeline() async throws {
        let kit = PKRuntime(languageModel: MockLLMService())
        let agent = try await kit.agents.create(
            name: "Retired Capability Agent",
            description: "Cannot own new ordinary Timelines after retirement."
        )
        try await kit.agents.retire(agent.id)
        let existingTimelineIDs = Set(try await kit.timelines.list().map(\.id))

        let error = await #expect(throws: AgentError.self) {
            _ = try await kit.timelines.create(title: "Rejected", attaching: agent.id)
        }

        if case let .agentRetired(actualID)? = error {
            #expect(actualID == agent.id)
        }
        #expect(Set(try await kit.timelines.list().map(\.id)) == existingTimelineIDs)
    }

    @Test("Model capability performs inference without Timeline persistence")
    func modelCapabilityIsTimelineFree() async throws {
        let llm = MockLLMService()
        llm.mockClient.nextResponse = "model-only"
        let messageStore = InMemoryMessageStore()
        let timelinePersistence = InMemoryTimelinePersistence()
        let kit = PKRuntime(configuration: .init(
            languageModel: llm,
            persistence: .init(
                runtimeRepository: InMemoryTimelineRuntimeRepository()
            )
        ))

        let result = try await kit.model.generate("No Timeline needed")

        #expect(result.content == "model-only")
        #expect(try await timelinePersistence.fetchAllTimelines(includeArchived: true).isEmpty)
        #expect(try await messageStore.fetchMessages(for: UUID()).isEmpty)
    }

    @Test("Timelines capability renames a persisted Timeline")
    func timelineCapabilityRenames() async throws {
        let kit = PKRuntime(languageModel: MockLLMService())
        let timeline = try await kit.timelines.create(title: "Before rename")

        try await kit.timelines.rename(timeline.id, to: "After rename")

        #expect(try await kit.timelines.get(timeline.id)?.title == "After rename")
        // The handle opened before the rename keeps addressing the same Timeline.
        let turn = try await timeline.startDirectTurn(
            "still reachable",
            context: DirectTurnContext(systemInstructions: "")
        )
        _ = await turn.events().collect()
        #expect(try await turn.outcome() == .completed)
    }

    @Test("Workspaces capability deletes a Workspace from the catalog")
    func workspaceCapabilityDeletes() async throws {
        let kit = PKRuntime(languageModel: MockLLMService())
        let workspace = try await kit.workspaces.create(
            uri: WorkspaceURI(parsing: "workspace://capability-delete")!,
            location: .runtime
        )

        try await kit.workspaces.delete(workspace.id)

        #expect(try await kit.workspaces.get(workspace.id) == nil)
    }

    @Test("Workspaces capability removes a workspace directory only when asked")
    func workspaceCapabilityDeletesDirectory() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pk-capability-delete-\(UUID().uuidString)", isDirectory: true)
        let directory = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let kit = PKRuntime(configuration: .init(
            languageModel: MockLLMService(),
            persistence: .inMemory(),
            runtime: .init(workspaceProfile: .hostManaged(root: root))
        ))
        let workspace = try await kit.workspaces.create(
            uri: WorkspaceURI(parsing: "workspace://capability-delete-directory")!,
            location: .runtime,
            rootPath: directory.path
        )

        try await kit.workspaces.delete(workspace.id, includingDirectory: true)

        #expect(try await kit.workspaces.get(workspace.id) == nil)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }
}
