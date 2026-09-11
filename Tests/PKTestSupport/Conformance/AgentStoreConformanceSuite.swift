import Foundation
import PKContracts
import PositronicKit
import struct PositronicKit.Thread
import Testing

/// Runs the documented behavioral checks for an ``AgentStoreProtocol`` implementation.
public enum AgentStoreConformanceSuite {
    /// Runs the Agent-store checks against an isolated store. The factory receives the threads
    /// that the query scenario requires before the store is returned.
    public static func run(
        makeStore: ([Thread]) async throws -> any AgentStoreProtocol
    ) async throws {
        try await runScenario("agent.empty") {
            try await emptyStoreReads(makeStore: makeStore)
        }
        try await runScenario("agent.save.fetch") {
            try await savesAndFetches(makeStore: makeStore)
        }
        try await runScenario("agent.replace") {
            try await replacesByID(makeStore: makeStore)
        }
        try await runScenario("agent.fetch-all") {
            try await fetchesAllAgents(makeStore: makeStore)
        }
        try await runScenario("agent.delete") {
            try await deletesOneAgent(makeStore: makeStore)
        }
        try await runScenario("agent.threads.filter") {
            try await fetchesAttachedThreads(makeStore: makeStore)
        }
    }

    private struct ScenarioError: Error, CustomStringConvertible {
        let id: String
        let underlying: Error

        var description: String { "\(id): \(String(describing: underlying))" }
    }

    private static func runScenario(
        _ id: String,
        operation: () async throws -> Void
    ) async throws {
        do {
            try await operation()
        } catch {
            if error is Testing.ExpectationFailedError {
                throw error
            }
            throw ScenarioError(id: id, underlying: error)
        }
    }

    private static func emptyStoreReads(
        makeStore: ([Thread]) async throws -> any AgentStoreProtocol
    ) async throws {
        let store = try await makeStore([])
        #expect(try await store.fetchAgent(id: UUID()) == nil, "agent.empty.fetch")
        #expect(try await store.fetchAllAgents().isEmpty, "agent.empty.all")
    }

    private static func savesAndFetches(
        makeStore: ([Thread]) async throws -> any AgentStoreProtocol
    ) async throws {
        let store = try await makeStore([])
        let agent = makeAgent()
        try await store.saveAgent(agent)
        try #require(try await store.fetchAgent(id: agent.id) == agent, "agent.save.fetch")
    }

    private static func replacesByID(
        makeStore: ([Thread]) async throws -> any AgentStoreProtocol
    ) async throws {
        let store = try await makeStore([])
        let id = UUID()
        try await store.saveAgent(makeAgent(id: id, name: "Original"))
        try await store.saveAgent(makeAgent(id: id, name: "Updated"))

        #expect(try await store.fetchAgent(id: id)?.name == "Updated", "agent.replace.value")
        #expect(try await store.fetchAllAgents().count == 1, "agent.replace.unique-id")
    }

    private static func fetchesAllAgents(
        makeStore: ([Thread]) async throws -> any AgentStoreProtocol
    ) async throws {
        let store = try await makeStore([])
        let agents = [makeAgent(), makeAgent(), makeAgent()]
        for agent in agents {
            try await store.saveAgent(agent)
        }

        #expect(Set(try await store.fetchAllAgents().map(\.id)) == Set(agents.map(\.id)), "agent.fetch-all.membership")
    }

    private static func deletesOneAgent(
        makeStore: ([Thread]) async throws -> any AgentStoreProtocol
    ) async throws {
        let store = try await makeStore([])
        let keep = makeAgent()
        let remove = makeAgent()
        try await store.saveAgent(keep)
        try await store.saveAgent(remove)

        try await store.deleteAgent(id: remove.id)
        #expect(try await store.fetchAgent(id: remove.id) == nil, "agent.delete.removes-target")
        #expect(try await store.fetchAgent(id: keep.id) == keep, "agent.delete.preserves-other")

        try await store.deleteAgent(id: UUID())
        #expect(try await store.fetchAgent(id: keep.id) != nil, "agent.delete.unknown-idempotent")
    }

    private static func fetchesAttachedThreads(
        makeStore: ([Thread]) async throws -> any AgentStoreProtocol
    ) async throws {
        let agentID = UUID()
        let otherAgentID = UUID()
        let attached = Thread(attachedAgentID: agentID)
        let other = Thread(attachedAgentID: otherAgentID)
        let detached = Thread()
        let store = try await makeStore([attached, other, detached])

        let threads = try await store.fetchThreads(attachedToAgent: agentID)
        #expect(threads.map(\.id) == [attached.id], "agent.threads.filter")
    }

    private static func makeAgent(
        id: UUID = UUID(),
        name: String = "Contract Agent"
    ) -> Agent {
        Agent(id: id, name: name, description: "description", privateThreadID: UUID())
    }
}
