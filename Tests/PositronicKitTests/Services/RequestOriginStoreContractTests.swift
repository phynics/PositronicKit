import Foundation
import PKShared
@testable import PositronicKit
import Testing

/// Contract tests for ``RequestOriginStoreProtocol``.
///
/// Exercises the protocol's CRUD requirements against every conformer available
/// within this package: the shipping in-memory store and a minimal test-only
/// dictionary-backed store. Downstream adapters (Monad's GRDB-backed
/// `RequestOriginRepository`, Yakamoz's SwiftData-backed
/// `SwiftDataRequestOriginStore`) are exercised in their respective consumer
/// test suites.
@Suite struct RequestOriginStoreContractTests {
    /// All conformers the contract must hold for, parameterized via `@Test(arguments:)`.
    enum Conformer: String, CaseIterable, Sendable {
        case inMemory = "InMemoryRequestOriginStore"
        case dictionary = "DictionaryRequestOriginStore"

        func make() -> any RequestOriginStoreProtocol {
            switch self {
            case .inMemory: InMemoryRequestOriginStore()
            case .dictionary: DictionaryRequestOriginStore()
            }
        }
    }

    private static func makeOrigin(
        id: UUID = UUID(),
        hostname: String = "host.example",
        displayName: String = "Example",
        platform: String = "macos"
    ) -> RequestOriginIdentity {
        RequestOriginIdentity(
            id: id,
            hostname: hostname,
            displayName: displayName,
            platform: platform
        )
    }

    private static func assertEqual(
        _ actual: RequestOriginIdentity?,
        _ expected: RequestOriginIdentity
    ) throws {
        let actual = try #require(actual)
        #expect(actual.id == expected.id)
        #expect(actual.hostname == expected.hostname)
        #expect(actual.displayName == expected.displayName)
        #expect(actual.platform == expected.platform)
    }

    // MARK: - Save & Fetch

    @Test(arguments: Conformer.allCases)
    func saveThenFetchByIdReturnsOrigin(conformer: Conformer) async throws {
        let store = conformer.make()
        let origin = Self.makeOrigin()

        try await store.saveOrigin(origin)
        let fetched = try await store.fetchOrigin(id: origin.id)

        try Self.assertEqual(fetched, origin)
    }

    @Test(arguments: Conformer.allCases)
    func fetchUnknownIdReturnsNil(conformer: Conformer) async throws {
        let store = conformer.make()

        let fetched = try await store.fetchOrigin(id: UUID())

        #expect(fetched == nil)
    }

    @Test(arguments: Conformer.allCases)
    func saveUpdatesExistingOriginOnIdCollision(conformer: Conformer) async throws {
        let store = conformer.make()
        let id = UUID()
        let original = Self.makeOrigin(id: id, displayName: "Original")
        let updated = Self.makeOrigin(id: id, displayName: "Updated")

        try await store.saveOrigin(original)
        try await store.saveOrigin(updated)

        let fetched = try await store.fetchOrigin(id: id)
        #expect(fetched?.displayName == "Updated")
    }

    // MARK: - Fetch All

    @Test(arguments: Conformer.allCases)
    func fetchAllReturnsEverySavedOrigin(conformer: Conformer) async throws {
        let store = conformer.make()
        let a = Self.makeOrigin(hostname: "a.host", displayName: "A")
        let b = Self.makeOrigin(hostname: "b.host", displayName: "B")
        let c = Self.makeOrigin(hostname: "c.host", displayName: "C")

        try await store.saveOrigin(a)
        try await store.saveOrigin(b)
        try await store.saveOrigin(c)

        let all = try await store.fetchAllOrigins()
        #expect(all.count == 3)
        let ids = Set(all.map(\.id))
        #expect(ids == Set([a.id, b.id, c.id]))
    }

    @Test(arguments: Conformer.allCases)
    func fetchAllOnEmptyStoreReturnsEmpty(conformer: Conformer) async throws {
        let store = conformer.make()

        let all = try await store.fetchAllOrigins()
        #expect(all.isEmpty)
    }

    // MARK: - Delete

    @Test(arguments: Conformer.allCases)
    func deleteExistingReturnsTrue(conformer: Conformer) async throws {
        let store = conformer.make()
        let origin = Self.makeOrigin()

        try await store.saveOrigin(origin)
        let deleted = try await store.deleteOrigin(id: origin.id)

        #expect(deleted == true)
    }

    @Test(arguments: Conformer.allCases)
    func deleteUnknownReturnsFalse(conformer: Conformer) async throws {
        let store = conformer.make()

        let deleted = try await store.deleteOrigin(id: UUID())

        #expect(deleted == false)
    }

    @Test(arguments: Conformer.allCases)
    func deleteRemovesOriginFromStore(conformer: Conformer) async throws {
        let store = conformer.make()
        let origin = Self.makeOrigin()

        try await store.saveOrigin(origin)
        _ = try await store.deleteOrigin(id: origin.id)

        let fetched = try await store.fetchOrigin(id: origin.id)
        #expect(fetched == nil)
    }

    @Test(arguments: Conformer.allCases)
    func deleteDoesNotAffectOtherOrigins(conformer: Conformer) async throws {
        let store = conformer.make()
        let keep = Self.makeOrigin(hostname: "keep.host", displayName: "Keep")
        let remove = Self.makeOrigin(hostname: "remove.host", displayName: "Remove")

        try await store.saveOrigin(keep)
        try await store.saveOrigin(remove)
        _ = try await store.deleteOrigin(id: remove.id)

        let all = try await store.fetchAllOrigins()
        #expect(all.count == 1)
        #expect(all.first?.id == keep.id)
    }
}

// MARK: - Minimal test-only conformer

/// Dictionary-backed `RequestOriginStoreProtocol` conformer used to prove the
/// contract is storage-agnostic (distinct from the array-backed
/// `InMemoryRequestOriginStore`).
private actor DictionaryRequestOriginStore: RequestOriginStoreProtocol {
    private var storage: [UUID: RequestOriginIdentity] = [:]

    func saveOrigin(_ origin: RequestOriginIdentity) async throws {
        storage[origin.id] = origin
    }

    func fetchOrigin(id: UUID) async throws -> RequestOriginIdentity? {
        storage[id]
    }

    func fetchAllOrigins() async throws -> [RequestOriginIdentity] {
        Array(storage.values)
    }

    func deleteOrigin(id: UUID) async throws -> Bool {
        storage.removeValue(forKey: id) != nil
    }
}
