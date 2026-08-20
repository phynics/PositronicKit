import Foundation
import PKContracts
import PKUtilities

/// Protocol for managing the lifecycle of agent instances through canonical Thread APIs.
public protocol AgentManagerProtocol: Sendable {
    func createInstance(
        from template: AgentTemplate?,
        name: String,
        description: String
    ) async throws -> Agent

    func attach(agentID: UUID, to threadID: UUID) async throws
    func detach(agentID: UUID, from threadID: UUID) async throws
    func getInstance(id: UUID) async throws -> Agent?
    func listInstances() async throws -> [Agent]
    func getThreads(attachedTo agentID: UUID) async throws -> [Thread]
    func updateInstance(_ instance: Agent) async throws
    func searchInstances(query: String) async throws -> [Agent]
    func deleteInstance(id: UUID, force: Bool) async throws
}

public extension AgentManagerProtocol {
    /// Returns an agent instance by its unique identifier.
    func instance(id: UUID) async throws -> Agent? {
        try await getInstance(id: id)
    }

    /// Returns all threads attached to a specific agent instance.
    func threads(attachedTo agentID: UUID) async throws -> [Thread] {
        try await getThreads(attachedTo: agentID)
    }

    func createInstance(
        from template: AgentTemplate? = nil,
        name: String,
        description: String
    ) async throws -> Agent {
        try await createInstance(from: template, name: name, description: description)
    }

    func deleteInstance(id: UUID, force: Bool = false) async throws {
        try await deleteInstance(id: id, force: force)
    }
}
