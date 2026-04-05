import MonadShared
/// Protocol for managing AgentTemplate definitions in persistent storage.

import Foundation

public protocol AgentTemplateStoreProtocol: Sendable {
    func saveAgentTemplate(_ agent: AgentTemplate) async throws
    func fetchAgentTemplate(id: UUID) async throws -> AgentTemplate?
    func fetchAgentTemplate(key: String) async throws -> AgentTemplate?
    func fetchAllAgentTemplates() async throws -> [AgentTemplate]
    func hasAgentTemplate(id: String) async -> Bool
}
