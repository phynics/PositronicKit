import Foundation
import PKContracts
import PKUtilities

/// Protocol for managing the lifecycle of agents through canonical Timeline APIs.
protocol AgentManagerProtocol: Sendable {
    func createAgent(
        from template: AgentTemplate?,
        name: String,
        description: String
    ) async throws -> Agent

    func attach(agentID: UUID, to timelineID: UUID) async throws
    func detach(agentID: UUID, from timelineID: UUID) async throws
    func getAgent(id: UUID) async throws -> Agent?
    func listAgents() async throws -> [Agent]
    func getTimelines(attachedTo agentID: UUID) async throws -> [TimelineRecord]
    func updateAgent(_ agent: Agent) async throws
    func searchAgents(query: String) async throws -> [Agent]
    func retireAgent(id: UUID) async throws
    func purgeAgent(id: UUID) async throws
    func deleteAgent(id: UUID, force: Bool) async throws
}

extension AgentManagerProtocol {
    /// Returns an agent by its unique identifier.
    func agent(id: UUID) async throws -> Agent? {
        try await getAgent(id: id)
    }

    /// Returns all timelines attached to a specific agent.
    func timelines(attachedTo agentID: UUID) async throws -> [TimelineRecord] {
        try await getTimelines(attachedTo: agentID)
    }

    func createAgent(
        from template: AgentTemplate? = nil,
        name: String,
        description: String
    ) async throws -> Agent {
        try await createAgent(from: template, name: name, description: description)
    }

    func deleteAgent(id: UUID, force: Bool = false) async throws {
        try await deleteAgent(id: id, force: force)
    }

    func retireAgent(id: UUID) async throws {
        try await retireAgent(id: id)
    }

    func purgeAgent(id: UUID) async throws {
        try await purgeAgent(id: id)
    }
}
