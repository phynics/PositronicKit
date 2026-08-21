import Foundation
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

        let turn = try await thread.startTurn(message: "hello")
        let events = await turn.events().collect()
        let outcome = await turn.outcome()

        #expect(events.contains { event in
            if case let .completion(.generationCompleted(message, _)) = event {
                return message.content == "managed reply"
            }
            return false
        })
        #expect(outcome == .completed)
        let repository = try #require(kit.runtimeRepository)
        let messages = try await repository.fetchMessages(for: thread.id)
        #expect(messages.last?.executionKind == .agentManaged)
        #expect(messages.last?.agentID == agent.id)
    }

    @Test("direct admission requires explicit context and preserves direct provenance")
    func directTurnUsesExplicitContext() async throws {
        let llm = MockLLMService()
        llm.mockClient.nextResponse = "direct reply"
        let kit = PositronicKit(languageModel: llm)
        let thread = try await kit.threads.create(title: "Direct")

        let turn = try await thread.startDirectTurn(
            message: "hello",
            context: DirectTurnContext(systemInstructions: "", contributor: .host)
        )
        _ = await turn.events().collect()

        #expect(await turn.outcome() == .completed)
        let repository = try #require(kit.runtimeRepository)
        let messages = try await repository.fetchMessages(for: thread.id)
        #expect(messages.last?.executionKind == .direct)
        #expect(messages.last?.agentID == nil)
    }

    @Test("managed and direct Turns retain provenance in mixed Thread history")
    func mixedHistoryPreservesProvenance() async throws {
        let llm = MockLLMService()
        llm.mockClient.nextResponse = "reply"
        let kit = PositronicKit(languageModel: llm)
        let thread = try await kit.threads.create(title: "Mixed")

        let direct = try await thread.startDirectTurn(
            message: "direct",
            context: DirectTurnContext(systemInstructions: "", contributor: .host)
        )
        _ = await direct.events().collect()
        #expect(await direct.outcome() == .completed)

        let agent = try await kit.agents.create(name: "Mixed Agent", description: "test")
        try await kit.agents.attach(agent.id, to: thread.id)
        let managed = try await thread.startTurn(message: "managed")
        _ = await managed.events().collect()

        let repository = try #require(kit.runtimeRepository)
        let assistantKinds = try await repository.fetchMessages(for: thread.id)
            .filter { $0.role == "assistant" }
            .map(\.executionKind)
        #expect(assistantKinds == [.direct, .agentManaged])
    }

    @Test("managed execution fails before persistence when no Agent is attached")
    func managedTurnRequiresAgent() async throws {
        let kit = PositronicKit(languageModel: MockLLMService())
        let thread = try await kit.threads.create(title: "Detached")

        let managedError = await #expect(throws: AgentError.self) {
            _ = try await thread.startTurn(message: "must not persist")
        }
        if case let .managedThreadRequiresAttachedAgent(threadID)? = managedError {
            #expect(threadID == thread.id)
        }

        let repository = try #require(kit.runtimeRepository)
        #expect(try await repository.fetchMessages(for: thread.id).isEmpty)
    }

    @Test("direct execution is rejected while an Agent is attached")
    func directTurnRequiresDetachedThread() async throws {
        let kit = PositronicKit(languageModel: MockLLMService())
        let thread = try await kit.threads.create(title: "Attached")
        let agent = try await kit.agents.create(name: "Attached Agent", description: "test")
        try await kit.agents.attach(agent.id, to: thread.id)

        let directError = await #expect(throws: AgentError.self) {
            _ = try await thread.startDirectTurn(
                message: "must not persist",
                context: DirectTurnContext(systemInstructions: "", contributor: .host)
            )
        }
        if case let .directTurnRequiresDetachedThread(threadID)? = directError {
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

        let first = try await thread.startTurn(message: "first")
        await #expect(throws: ThreadRuntimeRepositoryError.self) {
            _ = try await thread.startTurn(message: "second")
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
        let request = TurnRequest(threadID: thread.id, requestID: requestID, message: "same")

        let first = try await thread.startTurn(request)
        while llm.mockClient.neverFinishingStreamStartCount < 1 {
            await Task.yield()
        }
        let joined = try await thread.startTurn(request)
        #expect(joined.id == first.id)
        let repository = try #require(kit.runtimeRepository)
        let admitted = try #require(try await repository.fetchTurn(id: first.id))
        #expect(admitted.outcome == nil)
        await first.cancel()

        let events = await joined.events().collect()
        #expect(events.filter(\.isTerminal).count == 1)
        #expect(events.contains { event in
            if case .error(.generationCancelled) = event { return true }
            return false
        })
        let outcome = await joined.outcome()
        #expect(outcome == .cancelled(reason: "Turn task cancelled."))
    }
}
