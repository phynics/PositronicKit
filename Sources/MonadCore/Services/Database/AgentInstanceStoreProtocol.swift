import Foundation
import MonadShared

/// Protocol for persisting and querying agent instances.
public protocol AgentInstanceStoreProtocol: Sendable {
    func saveAgentInstance(_ instance: AgentInstance) async throws
    func fetchAgentInstance(id: UUID) async throws -> AgentInstance?
    func fetchAllAgentInstances() async throws -> [AgentInstance]
    func deleteAgentInstance(id: UUID) async throws
    func fetchTimelines(attachedToAgent agentInstanceId: UUID) async throws -> [Timeline]
}
