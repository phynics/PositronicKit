/// Protocol for persisting external request-origin identities and their hosted tool metadata.

import PKShared
import Foundation

public protocol ClientStoreProtocol: Sendable {
    func saveClient(_ client: ClientIdentity) async throws
    func fetchClient(id: UUID) async throws -> ClientIdentity?
    func fetchAllClients() async throws -> [ClientIdentity]
    func deleteClient(id: UUID) async throws -> Bool
    func fetchClientTools(clientId: UUID) async throws -> [ToolReference]
}
