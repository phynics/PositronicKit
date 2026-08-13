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

    @available(*, deprecated, message: "Timeline APIs are deprecated and will be removed in v4. Use the corresponding Thread API instead.")
    func attach(agentId: UUID, to timelineId: UUID) async throws {
        try await attach(agentID: agentId, to: timelineId)
    }

    @available(*, deprecated, message: "Timeline APIs are deprecated and will be removed in v4. Use the corresponding Thread API instead.")
    func detach(agentId: UUID, from timelineId: UUID) async throws {
        try await detach(agentID: agentId, from: timelineId)
    }

    @available(*, deprecated, renamed: "getThreads(attachedTo:)", message: "Timeline APIs are deprecated and will be removed in v4. Use the corresponding Thread API instead.")
    func getTimelines(attachedTo agentId: UUID) async throws -> [Timeline] {
        try await getThreads(attachedTo: agentId)
    }

    @available(*, deprecated, renamed: "threads(attachedTo:)", message: "Timeline APIs are deprecated and will be removed in v4. Use the corresponding Thread API instead.")
    func timelines(attachedTo agentID: UUID) async throws -> [Timeline] {
        try await threads(attachedTo: agentID)
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

/// Deprecated v3 requirements for existing timeline-named manager conformers.
@available(*, deprecated, message: "Timeline APIs are deprecated and will be removed in v4. Use the corresponding Thread API instead.")
public protocol TimelineAgentInstanceManagerProtocol: Sendable {
    func createInstance(
        from template: AgentTemplate?,
        name: String,
        description: String
    ) async throws -> AgentInstance

    func attach(agentId: UUID, to timelineId: UUID) async throws
    func detach(agentId: UUID, from timelineId: UUID) async throws
    func getInstance(id: UUID) async throws -> AgentInstance?
    func listInstances() async throws -> [AgentInstance]
    func getTimelines(attachedTo agentId: UUID) async throws -> [Timeline]
    func updateInstance(_ instance: AgentInstance) async throws
    func searchInstances(query: String) async throws -> [AgentInstance]
    func deleteInstance(id: UUID, force: Bool) async throws
}

/// Adapts a v3 timeline-named manager conformer to the canonical Thread protocol.
@available(*, deprecated, message: "Timeline APIs are deprecated and will be removed in v4. Use the corresponding Thread API instead.")
public actor LegacyAgentInstanceManagerAdapter: AgentInstanceManagerProtocol {
    private let legacy: any TimelineAgentInstanceManagerProtocol

    public init(_ legacy: any TimelineAgentInstanceManagerProtocol) {
        self.legacy = legacy
    }

    public func createInstance(
        from template: AgentTemplate?,
        name: String,
        description: String
    ) async throws -> AgentInstance {
        try await legacy.createInstance(from: template, name: name, description: description)
    }

    public func attach(agentID: UUID, to threadID: UUID) async throws {
        try await legacy.attach(agentId: agentID, to: threadID)
    }

    public func detach(agentID: UUID, from threadID: UUID) async throws {
        try await legacy.detach(agentId: agentID, from: threadID)
    }

    public func getInstance(id: UUID) async throws -> AgentInstance? {
        try await legacy.getInstance(id: id)
    }

    public func listInstances() async throws -> [AgentInstance] {
        try await legacy.listInstances()
    }

    public func getThreads(attachedTo agentID: UUID) async throws -> [Thread] {
        try await legacy.getTimelines(attachedTo: agentID)
    }

    public func updateInstance(_ instance: AgentInstance) async throws {
        try await legacy.updateInstance(instance)
    }

    public func searchInstances(query: String) async throws -> [AgentInstance] {
        try await legacy.searchInstances(query: query)
    }

    public func deleteInstance(id: UUID, force: Bool) async throws {
        try await legacy.deleteInstance(id: id, force: force)
    }
}
