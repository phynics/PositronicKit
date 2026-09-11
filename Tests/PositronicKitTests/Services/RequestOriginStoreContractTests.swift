import Foundation
import PKContracts
import PKTestSupport
import PositronicKit
import Testing

@Suite("RequestOriginStoreProtocol conformance")
struct RequestOriginStoreContractTests {
    @Test("InMemoryRequestOriginStore")
    func inMemoryStore() async throws {
        try await RequestOriginStoreConformanceSuite.run {
            InMemoryRequestOriginStore()
        }
    }

    @Test("independent dictionary-backed store")
    func dictionaryStore() async throws {
        try await RequestOriginStoreConformanceSuite.run {
            DictionaryRequestOriginStore()
        }
    }
}

private actor DictionaryRequestOriginStore: RequestOriginStoreProtocol {
    private var origins: [UUID: RequestOriginIdentity] = [:]

    func saveOrigin(_ origin: RequestOriginIdentity) async throws {
        origins[origin.id] = origin
    }

    func fetchOrigin(id: UUID) async throws -> RequestOriginIdentity? {
        origins[id]
    }

    func fetchAllOrigins() async throws -> [RequestOriginIdentity] {
        Array(origins.values)
    }

    func deleteOrigin(id: UUID) async throws -> Bool {
        origins.removeValue(forKey: id) != nil
    }
}
