/// Protocol for persisting external request-origin identities and their hosted tool metadata.

import PKShared
import Foundation

public protocol RequestOriginStoreProtocol: Sendable {
    func saveOrigin(_ origin: RequestOriginIdentity) async throws
    func fetchOrigin(id: UUID) async throws -> RequestOriginIdentity?
    func fetchAllOrigins() async throws -> [RequestOriginIdentity]
    func deleteOrigin(id: UUID) async throws -> Bool
    func fetchOriginTools(originId: UUID) async throws -> [ToolReference]
}

public protocol ClientStoreProtocol: RequestOriginStoreProtocol {
    func saveClient(_ client: ClientIdentity) async throws
    func fetchClient(id: UUID) async throws -> ClientIdentity?
    func fetchAllClients() async throws -> [ClientIdentity]
    func deleteClient(id: UUID) async throws -> Bool
}

public extension ClientStoreProtocol {
    func saveOrigin(_ origin: RequestOriginIdentity) async throws {
        try await saveClient(origin)
    }

    func fetchOrigin(id: UUID) async throws -> RequestOriginIdentity? {
        try await fetchClient(id: id)
    }

    func fetchAllOrigins() async throws -> [RequestOriginIdentity] {
        try await fetchAllClients()
    }

    func deleteOrigin(id: UUID) async throws -> Bool {
        try await deleteClient(id: id)
    }
}
