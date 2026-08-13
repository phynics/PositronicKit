import Foundation
import PKShared
import PKUtilities

/// Thread-safe in-memory agent instance store for prototyping and development.
public actor InMemoryAgentInstanceStore: AgentInstanceStoreProtocol {
    private var instances: [AgentInstance] = []

    public init() {}

    public func saveAgentInstance(_ instance: AgentInstance) async throws {
        if let index = instances.firstIndex(where: { $0.id == instance.id }) {
            instances[index] = instance
        } else {
            instances.append(instance)
        }
    }

    public func fetchAgentInstance(id: UUID) async throws -> AgentInstance? {
        instances.first { $0.id == id }
    }

    public func fetchAllAgentInstances() async throws -> [AgentInstance] {
        instances
    }

    public func deleteAgentInstance(id: UUID) async throws {
        instances.removeAll { $0.id == id }
    }

    public func fetchThreads(attachedToAgent _: UUID) async throws -> [Thread] {
        []
    }

    @available(*, deprecated, message: "Timeline APIs are deprecated and will be removed in v4. Use the corresponding Thread API instead.")
    public func fetchTimelines(attachedToAgent agentInstanceID: UUID) async throws -> [Thread] {
        try await fetchThreads(attachedToAgent: agentInstanceID)
    }
}
