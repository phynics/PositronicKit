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
