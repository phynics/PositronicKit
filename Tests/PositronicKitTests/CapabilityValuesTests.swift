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

    @Test("Model capability performs inference without Thread persistence")
    func modelCapabilityIsThreadFree() async throws {
        let llm = MockLLMService()
        llm.mockClient.nextResponse = "model-only"
        let messageStore = InMemoryMessageStore()
        let threadPersistence = InMemoryThreadPersistence()
        let kit = PositronicKit(configuration: .init(
            provider: .init(languageModel: llm),
            persistence: .init(
                messageStore: messageStore,
                threadPersistence: threadPersistence
            )
        ))

        let result = try await kit.model.generate("No Thread needed")

        #expect(result.content == "model-only")
        #expect(try await threadPersistence.fetchAllThreads(includeArchived: true).isEmpty)
        #expect(try await messageStore.fetchMessages(for: UUID()).isEmpty)
    }
}
