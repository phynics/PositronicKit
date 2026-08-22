import Foundation
import PKContracts

/// Agent lifecycle entry points exposed by ``PositronicKit``.
public struct AgentCapability: Sendable {
    private let kit: PositronicKit

    init(kit: PositronicKit) {
        self.kit = kit
    }

    public func create(
        name: String,
        description: String,
        template: AgentTemplate? = nil
    ) async throws -> Agent {
        try await kit.agentManager.createAgent(
            from: template,
            name: name,
            description: description
        )
    }

    public func get(_ agentID: UUID) async throws -> Agent? {
        try await kit.agentManager.getAgent(id: agentID)
    }

    /// Updates an Agent's durable identity fields. The next admitted managed Turn observes
    /// the change; an already-admitted Turn keeps its captured context.
    public func update(_ agent: Agent) async throws {
        try await kit.agentManager.updateAgent(agent)
    }

    public func list() async throws -> [Agent] {
        try await kit.agentManager.listAgents()
    }

    public func attach(_ agentID: UUID, to threadID: UUID) async throws {
        try await kit.agentManager.attach(agentID: agentID, to: threadID)
    }

    public func detach(_ agentID: UUID, from threadID: UUID) async throws {
        try await kit.agentManager.detach(agentID: agentID, from: threadID)
    }

    public func threads(attachedTo agentID: UUID) async throws -> [Thread] {
        try await kit.agentManager.getThreads(attachedTo: agentID)
    }

    /// Begins the drain-to-retired lifecycle. Admitted Turns finish before ordinary
    /// attachments are detached and the primary Thread is archived.
    public func retire(_ agentID: UUID) async throws {
        try await kit.agentManager.retireAgent(id: agentID)
    }

    /// Permanently removes a retired Agent and its owned primary resources.
    public func purge(_ agentID: UUID) async throws {
        try await kit.agentManager.purgeAgent(id: agentID)
    }
}
