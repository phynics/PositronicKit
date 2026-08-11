import Foundation
import PKShared
import PKUtilities

/// Protocol for managing the lifecycle of agent instances.
public protocol AgentInstanceManagerProtocol: Sendable {
    /// Creates a new agent instance, its private workspace, and its private timeline atomically.
    func createInstance(
        from template: AgentTemplate?,
        name: String,
        description: String
    ) async throws -> AgentInstance

    /// Attaches an agent instance to a timeline.
    func attach(agentId: UUID, to timelineId: UUID) async throws

    /// Detaches an agent instance from a timeline.
    func detach(agentId: UUID, from timelineId: UUID) async throws

    /// Fetches an agent instance by its unique identifier.
    func getInstance(id: UUID) async throws -> AgentInstance?

    /// Lists all agent instances.
    func listInstances() async throws -> [AgentInstance]

    /// Lists all timelines attached to a specific agent instance.
    func getTimelines(attachedTo agentId: UUID) async throws -> [Timeline]

    /// Updates an existing agent instance.
    func updateInstance(_ instance: AgentInstance) async throws

    /// Searches for agent instances by name, description, or ID.
    func searchInstances(query: String) async throws -> [AgentInstance]

    /// Deletes an agent instance.
    func deleteInstance(id: UUID, force: Bool) async throws
}

extension AgentInstanceManagerProtocol {
    /// Attaches an agent instance using the canonical identifier spellings.
    public func attach(agentID: UUID, to timelineID: UUID) async throws {
        try await attach(agentId: agentID, to: timelineID)
    }

    /// Detaches an agent instance using the canonical identifier spellings.
    public func detach(agentID: UUID, from timelineID: UUID) async throws {
        try await detach(agentId: agentID, from: timelineID)
    }

    /// Returns an agent instance by its unique identifier.
    public func instance(id: UUID) async throws -> AgentInstance? {
        try await getInstance(id: id)
    }

    /// Returns all timelines attached to a specific agent instance.
    public func timelines(attachedTo agentID: UUID) async throws -> [Timeline] {
        try await getTimelines(attachedTo: agentID)
    }

    public func createInstance(
        from template: AgentTemplate? = nil,
        name: String,
        description: String
    ) async throws -> AgentInstance {
        try await createInstance(from: template, name: name, description: description)
    }

    public func deleteInstance(id: UUID, force: Bool = false) async throws {
        try await deleteInstance(id: id, force: force)
    }
}
