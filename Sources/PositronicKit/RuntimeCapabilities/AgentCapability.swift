import Foundation
import PKContracts

/// Agent lifecycle entry points exposed by ``PKRuntime``.
public struct AgentCapability: Sendable {
    private let agentManager: AgentManager

    init(agentManager: AgentManager) {
        self.agentManager = agentManager
    }

    public func create(
        name: String,
        description: String,
        template: AgentTemplate? = nil
    ) async throws -> Agent {
        try await agentManager.createAgent(
            from: template,
            name: name,
            description: description
        )
    }

    public func get(_ agentID: UUID) async throws -> Agent? {
        try await agentManager.getAgent(id: agentID)
    }

    /// Updates an Agent's durable identity fields. The next admitted managed Turn observes
    /// the change; an already-admitted Turn keeps its captured context.
    public func update(_ agent: Agent) async throws {
        try await agentManager.updateAgent(agent)
    }

    public func list() async throws -> [Agent] {
        try await agentManager.listAgents()
    }

    public func attach(_ agentID: UUID, to timelineID: UUID) async throws {
        try await agentManager.attach(agentID: agentID, to: timelineID)
    }

    public func detach(_ agentID: UUID, from timelineID: UUID) async throws {
        try await agentManager.detach(agentID: agentID, from: timelineID)
    }

    public func timelines(attachedTo agentID: UUID) async throws -> [TimelineRecord] {
        try await agentManager.getTimelines(attachedTo: agentID)
    }

    /// Begins the drain-to-retired lifecycle. Admitted Turns finish before ordinary
    /// attachments are detached and the primary Timeline is archived.
    public func retire(_ agentID: UUID) async throws {
        try await agentManager.retireAgent(id: agentID)
    }

    /// Permanently removes a retired Agent and its owned primary resources.
    public func purge(_ agentID: UUID) async throws {
        try await agentManager.purgeAgent(id: agentID)
    }
}
