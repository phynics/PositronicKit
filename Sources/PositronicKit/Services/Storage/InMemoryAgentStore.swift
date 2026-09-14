import Foundation
import PKContracts
import PKUtilities

/// Timeline-safe in-memory agent store for prototyping and development.
public actor InMemoryAgentStore: AgentStoreProtocol {
    private var instances: [Agent] = []
    private var timelines: [TimelineRecord]

    public init() {
        timelines = []
    }

    package init(timelines: [TimelineRecord]) {
        self.timelines = timelines
    }

    public func saveAgent(_ instance: Agent) async throws {
        if let index = instances.firstIndex(where: { $0.id == instance.id }) {
            instances[index] = instance
        } else {
            instances.append(instance)
        }
    }

    public func fetchAgent(id: UUID) async throws -> Agent? {
        instances.first { $0.id == id }
    }

    public func fetchAllAgents() async throws -> [Agent] {
        instances
    }

    public func deleteAgent(id: UUID) async throws {
        instances.removeAll { $0.id == id }
    }

    public func fetchTimelines(attachedToAgent agentID: UUID) async throws -> [TimelineRecord] {
        timelines.filter { $0.attachedAgentID == agentID }
    }
}
