import Foundation
import PKContracts
import struct PositronicKit.Thread
@testable import PositronicKit
import Testing

/// Contract tests for ``AgentStoreProtocol``.
///
/// Exercises the protocol's CRUD and query requirements against every conformer
/// available within this package: the shipping in-memory store and a minimal
/// test-only dictionary-backed store. Downstream adapters (Monad's GRDB-backed
/// `AgentDataRepository`, Yakamoz's SwiftData-backed
/// `SwiftDataAgentStore`) are exercised in their respective consumer test
/// suites.
@Suite struct AgentStoreContractTests {
    /// All conformers the contract must hold for, parameterized via `@Test(arguments:)`.
    enum Conformer: String, CaseIterable, Sendable {
        case inMemory = "InMemoryAgentStore"
        case dictionary = "DictionaryAgentStore"

        func make() -> any AgentStoreProtocol {
            switch self {
            case .inMemory: InMemoryAgentStore()
            case .dictionary: DictionaryAgentStore()
            }
        }
    }

    private static func makeInstance(
        id: UUID = UUID(),
        name: String = "Contract Agent",
        description: String = "desc"
    ) -> Agent {
        Agent(
            id: id,
            name: name,
            description: description,
            privateThreadID: UUID()
        )
    }

    // MARK: - Save & Fetch

    @Test(arguments: Conformer.allCases)
    func saveThenFetchByIdReturnsInstance(conformer: Conformer) async throws {
        let store = conformer.make()
        let instance = Self.makeInstance()

        try await store.saveAgent(instance)
        let fetched = try await store.fetchAgent(id: instance.id)

        #expect(fetched == instance)
    }

    @Test(arguments: Conformer.allCases)
    func fetchUnknownIdReturnsNil(conformer: Conformer) async throws {
        let store = conformer.make()

        let fetched = try await store.fetchAgent(id: UUID())

        #expect(fetched == nil)
    }

    @Test(arguments: Conformer.allCases)
    func saveUpdatesExistingInstanceOnIdCollision(conformer: Conformer) async throws {
        let store = conformer.make()
        let id = UUID()
        let original = Self.makeInstance(id: id, name: "Original")
        let updated = Self.makeInstance(id: id, name: "Updated")

        try await store.saveAgent(original)
        try await store.saveAgent(updated)

        let fetched = try await store.fetchAgent(id: id)
        #expect(fetched?.name == "Updated")
    }

    // MARK: - Fetch All

    @Test(arguments: Conformer.allCases)
    func fetchAllReturnsEverySavedInstance(conformer: Conformer) async throws {
        let store = conformer.make()
        let a = Self.makeInstance(name: "A")
        let b = Self.makeInstance(name: "B")
        let c = Self.makeInstance(name: "C")

        try await store.saveAgent(a)
        try await store.saveAgent(b)
        try await store.saveAgent(c)

        let all = try await store.fetchAllAgents()
        #expect(all.count == 3)
        let ids = Set(all.map(\.id))
        #expect(ids == Set([a.id, b.id, c.id]))
    }

    @Test(arguments: Conformer.allCases)
    func fetchAllOnEmptyStoreReturnsEmpty(conformer: Conformer) async throws {
        let store = conformer.make()

        let all = try await store.fetchAllAgents()
        #expect(all.isEmpty)
    }

    // MARK: - Delete

    @Test(arguments: Conformer.allCases)
    func deleteRemovesInstance(conformer: Conformer) async throws {
        let store = conformer.make()
        let instance = Self.makeInstance()

        try await store.saveAgent(instance)
        try await store.deleteAgent(id: instance.id)

        let fetched = try await store.fetchAgent(id: instance.id)
        #expect(fetched == nil)
    }

    @Test(arguments: Conformer.allCases)
    func deleteUnknownIdDoesNotThrow(conformer: Conformer) async throws {
        let store = conformer.make()

        // Deleting a non-existent instance must not throw — it's idempotent.
        try await store.deleteAgent(id: UUID())
    }

    @Test(arguments: Conformer.allCases)
    func deleteDoesNotAffectOtherInstances(conformer: Conformer) async throws {
        let store = conformer.make()
        let keep = Self.makeInstance(name: "Keep")
        let remove = Self.makeInstance(name: "Remove")

        try await store.saveAgent(keep)
        try await store.saveAgent(remove)
        try await store.deleteAgent(id: remove.id)

        let all = try await store.fetchAllAgents()
        #expect(all.count == 1)
        #expect(all.first?.id == keep.id)
    }

    // MARK: - Fetch Threads

    @Test(arguments: Conformer.allCases)
    func fetchThreadsWorksThroughProtocolExistential(conformer: Conformer) async throws {
        let store: any AgentStoreProtocol = conformer.make()
        let instance = Self.makeInstance()

        try await store.saveAgent(instance)

        let threads = try await store.fetchThreads(attachedToAgent: instance.id)
        #expect(threads.isEmpty)
    }

    @Test(arguments: Conformer.allCases)
    func fetchThreadsRemainsAvailable(conformer: Conformer) async throws {
        let store: any AgentStoreProtocol = conformer.make()
        let instance = Self.makeInstance()

        try await store.saveAgent(instance)

        let threads = try await store.fetchThreads(attachedToAgent: instance.id)
        #expect(threads.isEmpty)
    }
}

// MARK: - Minimal test-only conformer

/// Dictionary-backed `AgentStoreProtocol` conformer used to prove the
/// contract is storage-agnostic (distinct from the array-backed
/// `InMemoryAgentStore`).
private actor DictionaryAgentStore: AgentStoreProtocol {
    private var storage: [UUID: Agent] = [:]

    func saveAgent(_ instance: Agent) async throws {
        storage[instance.id] = instance
    }

    func fetchAgent(id: UUID) async throws -> Agent? {
        storage[id]
    }

    func fetchAllAgents() async throws -> [Agent] {
        Array(storage.values)
    }

    func deleteAgent(id: UUID) async throws {
        storage.removeValue(forKey: id)
    }

    func fetchThreads(attachedToAgent _: UUID) async throws -> [Thread] {
        []
    }
}
