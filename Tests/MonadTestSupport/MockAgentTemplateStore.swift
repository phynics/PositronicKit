import MonadShared
import MonadCore
import Foundation

public final class MockAgentTemplateStore: AgentTemplateStoreProtocol, @unchecked Sendable {
    public var agentTemplates: [AgentTemplate] = []

    public init() {}

    public func saveAgentTemplate(_ agent: AgentTemplate) async throws {
        if let index = agentTemplates.firstIndex(where: { $0.id == agent.id }) {
            agentTemplates[index] = agent
        } else {
            agentTemplates.append(agent)
        }
    }

    public func fetchAgentTemplate(id: UUID) async throws -> AgentTemplate? {
        return agentTemplates.first(where: { $0.id == id })
    }

    public func fetchAgentTemplate(key: String) async throws -> AgentTemplate? {
        if key == "default" {
            return agentTemplates.first
        }
        if let uuid = UUID(uuidString: key) {
            return agentTemplates.first(where: { $0.id == uuid })
        }
        return nil
    }

    public func fetchAllAgentTemplates() async throws -> [AgentTemplate] {
        return agentTemplates
    }

    public func hasAgentTemplate(id: String) async -> Bool {
        if let uuid = UUID(uuidString: id) {
             return agentTemplates.contains(where: { $0.id == uuid })
        }
        return false
    }
}
