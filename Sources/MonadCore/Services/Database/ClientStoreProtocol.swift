/// Protocol for managing remote client identities and their connection state.

import MonadShared
import Foundation

public protocol ClientStoreProtocol: Sendable {
    func saveClient(_ client: ClientIdentity) async throws
    func fetchClient(id: UUID) async throws -> ClientIdentity?
    func fetchAllClients() async throws -> [ClientIdentity]
    func deleteClient(id: UUID) async throws -> Bool
    func fetchClientTools(clientId: UUID) async throws -> [ToolReference]
}
