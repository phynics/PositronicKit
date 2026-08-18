import Foundation
import PKShared
import PKUtilities

/// Protocol for managing the lifecycle of agent instances through canonical Thread APIs.
public protocol AgentInstanceManagerProtocol: Sendable {
    func createInstance(
        from template: AgentTemplate?,
        name: String,
        description: String
    ) async throws -> AgentInstance

    func attach(agentID: UUID, to threadID: UUID) async throws
    func detach(agentID: UUID, from threadID: UUID) async throws
    func getInstance(id: UUID) async throws -> AgentInstance?
    func listInstances() async throws -> [AgentInstance]
    func getThreads(attachedTo agentID: UUID) async throws -> [Thread]
    func updateInstance(_ instance: AgentInstance) async throws
    func searchInstances(query: String) async throws -> [AgentInstance]
    func deleteInstance(id: UUID, force: Bool) async throws
}

public extension AgentInstanceManagerProtocol {
    /// Returns an agent instance by its unique identifier.
    func instance(id: UUID) async throws -> AgentInstance? {
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
    ) async throws -> AgentInstance {
        try await createInstance(from: template, name: name, description: description)
    }

    func deleteInstance(id: UUID, force: Bool = false) async throws {
        try await deleteInstance(id: id, force: force)
    }
}
