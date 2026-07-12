import Foundation
import PKShared
@testable import PositronicKit
import Testing

/// Contract tests for ``AgentInstanceStoreProtocol``.
///
/// Exercises the protocol's CRUD and query requirements against every conformer
/// available within this package: the shipping in-memory store and a minimal
/// test-only dictionary-backed store. Downstream adapters (Monad's GRDB-backed
/// `AgentInstanceDataRepository`, Yakamoz's SwiftData-backed
/// `SwiftDataAgentInstanceStore`) are exercised in their respective consumer test
/// suites.
@Suite struct AgentInstanceStoreContractTests {
    /// All conformers the contract must hold for, parameterized via `@Test(arguments:)`.
    enum Conformer: String, CaseIterable, Sendable {
        case inMemory = "InMemoryAgentInstanceStore"
        case dictionary = "DictionaryAgentInstanceStore"

        func make() -> any AgentInstanceStoreProtocol {
            switch self {
            case .inMemory: InMemoryAgentInstanceStore()
            case .dictionary: DictionaryAgentInstanceStore()
            }
        }
    }

    private static func makeInstance(
        id: UUID = UUID(),
        name: String = "Contract Agent",
        description: String = "desc"
    ) -> AgentInstance {
        AgentInstance(
            id: id,
            name: name,
            description: description,
            privateTimelineId: UUID()
        )
    }

    // MARK: - Save & Fetch

    @Test(arguments: Conformer.allCases)
    func saveThenFetchByIdReturnsInstance(conformer: Conformer) async throws {
        let store = conformer.make()
        let instance = Self.makeInstance()

        try await store.saveAgentInstance(instance)
        let fetched = try await store.fetchAgentInstance(id: instance.id)

        #expect(fetched == instance)
    }

    @Test(arguments: Conformer.allCases)
    func fetchUnknownIdReturnsNil(conformer: Conformer) async throws {
        let store = conformer.make()

        let fetched = try await store.fetchAgentInstance(id: UUID())

        #expect(fetched == nil)
    }

    @Test(arguments: Conformer.allCases)
    func saveUpdatesExistingInstanceOnIdCollision(conformer: Conformer) async throws {
        let store = conformer.make()
        let id = UUID()
        let original = Self.makeInstance(id: id, name: "Original")
        let updated = Self.makeInstance(id: id, name: "Updated")

        try await store.saveAgentInstance(original)
        try await store.saveAgentInstance(updated)

        let fetched = try await store.fetchAgentInstance(id: id)
        #expect(fetched?.name == "Updated")
    }

    // MARK: - Fetch All

    @Test(arguments: Conformer.allCases)
    func fetchAllReturnsEverySavedInstance(conformer: Conformer) async throws {
        let store = conformer.make()
        let a = Self.makeInstance(name: "A")
        let b = Self.makeInstance(name: "B")
        let c = Self.makeInstance(name: "C")

        try await store.saveAgentInstance(a)
        try await store.saveAgentInstance(b)
        try await store.saveAgentInstance(c)

        let all = try await store.fetchAllAgentInstances()
        #expect(all.count == 3)
        let ids = Set(all.map(\.id))
        #expect(ids == Set([a.id, b.id, c.id]))
    }

    @Test(arguments: Conformer.allCases)
    func fetchAllOnEmptyStoreReturnsEmpty(conformer: Conformer) async throws {
        let store = conformer.make()

        let all = try await store.fetchAllAgentInstances()
        #expect(all.isEmpty)
    }

    // MARK: - Delete

    @Test(arguments: Conformer.allCases)
    func deleteRemovesInstance(conformer: Conformer) async throws {
        let store = conformer.make()
        let instance = Self.makeInstance()

        try await store.saveAgentInstance(instance)
        try await store.deleteAgentInstance(id: instance.id)

        let fetched = try await store.fetchAgentInstance(id: instance.id)
        #expect(fetched == nil)
    }

    @Test(arguments: Conformer.allCases)
    func deleteUnknownIdDoesNotThrow(conformer: Conformer) async throws {
        let store = conformer.make()

        // Deleting a non-existent instance must not throw — it's idempotent.
        try await store.deleteAgentInstance(id: UUID())
    }

    @Test(arguments: Conformer.allCases)
    func deleteDoesNotAffectOtherInstances(conformer: Conformer) async throws {
        let store = conformer.make()
        let keep = Self.makeInstance(name: "Keep")
        let remove = Self.makeInstance(name: "Remove")

        try await store.saveAgentInstance(keep)
        try await store.saveAgentInstance(remove)
        try await store.deleteAgentInstance(id: remove.id)

        let all = try await store.fetchAllAgentInstances()
        #expect(all.count == 1)
        #expect(all.first?.id == keep.id)
    }

    // MARK: - Fetch Timelines

    @Test(arguments: Conformer.allCases)
    func fetchTimelinesReturnsEmptyForAgentWithNoneAttached(conformer: Conformer) async throws {
        let store = conformer.make()
        let instance = Self.makeInstance()

        try await store.saveAgentInstance(instance)

        let timelines = try await store.fetchTimelines(attachedToAgent: instance.id)
        #expect(timelines.isEmpty)
    }
}

// MARK: - Minimal test-only conformer

/// Dictionary-backed `AgentInstanceStoreProtocol` conformer used to prove the
/// contract is storage-agnostic (distinct from the array-backed
/// `InMemoryAgentInstanceStore`).
private actor DictionaryAgentInstanceStore: AgentInstanceStoreProtocol {
    private var storage: [UUID: AgentInstance] = [:]

    func saveAgentInstance(_ instance: AgentInstance) async throws {
        storage[instance.id] = instance
    }

    func fetchAgentInstance(id: UUID) async throws -> AgentInstance? {
        storage[id]
    }

    func fetchAllAgentInstances() async throws -> [AgentInstance] {
        Array(storage.values)
    }

    func deleteAgentInstance(id: UUID) async throws {
        storage.removeValue(forKey: id)
    }

    func fetchTimelines(attachedToAgent _: UUID) async throws -> [Timeline] {
        []
    }
}
