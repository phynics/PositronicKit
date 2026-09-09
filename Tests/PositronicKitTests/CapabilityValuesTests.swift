import Foundation
import PKTestSupport
import PositronicKit
import Testing

@Suite("Facade capability values")
struct CapabilityValuesTests {
    @Test("Threads capability creates and reopens a stateful handle")
    func threadCapabilityOwnsHandleLifecycle() async throws {
        let kit = PositronicKit(languageModel: MockLLMService())

        let handle = try await kit.threads.create(title: "Capability Thread")
        let reopened = kit.threads.open(handle.id)

        #expect(reopened.id == handle.id)
        #expect(try await kit.threads.get(handle.id)?.title == "Capability Thread")
    }

    @Test("Agents capability attaches an identity to a Thread")
    func agentCapabilityOwnsAttachment() async throws {
        let kit = PositronicKit(languageModel: MockLLMService())
        let thread = try await kit.threads.create(title: "Managed Thread")
        let agent = try await kit.agents.create(
            name: "Capability Agent",
            description: "Exercises the capability surface."
        )

        try await kit.agents.attach(agent.id, to: thread.id)
        let attachedThreads = try await kit.agents.threads(attachedTo: agent.id)

        #expect(Set(attachedThreads.map(\.id)) == [thread.id, agent.privateThreadID])
    }

    @Test("Threads capability creates an ordinary Thread attached to an existing Agent")
    func createsAttachedThread() async throws {
        let llm = MockLLMService()
        llm.mockClient.nextResponse = "ready"
        let kit = PositronicKit(languageModel: llm)
        let agent = try await kit.agents.create(
            name: "Managed Capability Agent",
            description: "Owns the new ordinary Thread."
        )

        let thread = try await kit.threads.create(
            title: "Research",
            attaching: agent.id
        )

        #expect(try await kit.threads.get(thread.id)?.attachedAgentID == agent.id)
        let turn = try await thread.startTurn("Start immediately")
        _ = await turn.events().collect()
        #expect(try await turn.outcome() == .completed)
    }

    @Test("attached Thread creation rejects a missing Agent before creating a Thread")
    func rejectsMissingAgentWithoutCreatingThread() async throws {
        let kit = PositronicKit(languageModel: MockLLMService())
        let missingAgentID = UUID()

        let error = await #expect(throws: AgentError.self) {
            _ = try await kit.threads.create(title: "Orphan", attaching: missingAgentID)
        }

        if case let .agentNotFound(actualID)? = error {
            #expect(actualID == missingAgentID)
        }
        #expect(try await kit.threads.list().isEmpty)
    }

    @Test("attached Thread creation rejects a retired Agent without creating a Thread")
    func rejectsRetiredAgentWithoutCreatingThread() async throws {
        let kit = PositronicKit(languageModel: MockLLMService())
        let agent = try await kit.agents.create(
            name: "Retired Capability Agent",
            description: "Cannot own new ordinary Threads after retirement."
        )
        try await kit.agents.retire(agent.id)
        let existingThreadIDs = Set(try await kit.threads.list().map(\.id))

        let error = await #expect(throws: AgentError.self) {
            _ = try await kit.threads.create(title: "Rejected", attaching: agent.id)
        }

        if case let .agentRetired(actualID)? = error {
            #expect(actualID == agent.id)
        }
        #expect(Set(try await kit.threads.list().map(\.id)) == existingThreadIDs)
    }

    @Test("Model capability performs inference without Thread persistence")
    func modelCapabilityIsThreadFree() async throws {
        let llm = MockLLMService()
        llm.mockClient.nextResponse = "model-only"
        let messageStore = InMemoryMessageStore()
        let threadPersistence = InMemoryThreadPersistence()
        let kit = PositronicKit(configuration: .init(
            provider: .init(languageModel: llm),
            persistence: .init(
                runtimeRepository: InMemoryThreadRuntimeRepository()
            )
        ))

        let result = try await kit.model.generate("No Thread needed")

        #expect(result.content == "model-only")
        #expect(try await threadPersistence.fetchAllThreads(includeArchived: true).isEmpty)
        #expect(try await messageStore.fetchMessages(for: UUID()).isEmpty)
    }
}
