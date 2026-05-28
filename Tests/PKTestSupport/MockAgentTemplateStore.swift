import PKShared
import PositronicKit
import Foundation
import Synchronization

public final class MockAgentTemplateStore: AgentTemplateStoreProtocol, @unchecked Sendable {
    private let templatesState = Mutex<[AgentTemplate]>([])

    public var agentTemplates: [AgentTemplate] {
        get { templatesState.withLock { $0 } }
        set { templatesState.withLock { $0 = newValue } }
    }

    public init() {}

    public func saveAgentTemplate(_ agent: AgentTemplate) async throws {
        templatesState.withLock {
            if let index = $0.firstIndex(where: { $0.id == agent.id }) {
                $0[index] = agent
            } else {
                $0.append(agent)
            }
        }
    }

    public func fetchAgentTemplate(id: UUID) async throws -> AgentTemplate? {
        templatesState.withLock {
            $0.first { $0.id == id }
        }
    }

    public func fetchAgentTemplate(key: String) async throws -> AgentTemplate? {
        templatesState.withLock {
            if key == "default" {
                return $0.first
            }
            if let uuid = UUID(uuidString: key) {
                return $0.first { $0.id == uuid }
            }
            return nil
        }
    }

    public func fetchAllAgentTemplates() async throws -> [AgentTemplate] {
        templatesState.withLock { $0 }
    }

    public func hasAgentTemplate(id: String) async -> Bool {
        guard let uuid = UUID(uuidString: id) else { return false }
        return templatesState.withLock {
            $0.contains { $0.id == uuid }
        }
    }
}
