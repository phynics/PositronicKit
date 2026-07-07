import Foundation
import PKShared

/// Thread-safe in-memory request-origin store for prototyping and development.
public actor InMemoryRequestOriginStore: RequestOriginStoreProtocol {
    private var origins: [RequestOriginIdentity] = []

    public init() {}

    public func saveOrigin(_ origin: RequestOriginIdentity) async throws {
        if let index = origins.firstIndex(where: { $0.id == origin.id }) {
            origins[index] = origin
        } else {
            origins.append(origin)
        }
    }

    public func fetchOrigin(id: UUID) async throws -> RequestOriginIdentity? {
        origins.first { $0.id == id }
    }

    public func fetchAllOrigins() async throws -> [RequestOriginIdentity] {
        origins
    }

    public func deleteOrigin(id: UUID) async throws -> Bool {
        let count = origins.count
        origins.removeAll { $0.id == id }
        return origins.count < count
    }

}
