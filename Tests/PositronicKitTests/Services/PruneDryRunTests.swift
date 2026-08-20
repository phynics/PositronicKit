import Foundation
@testable import PKContracts
import PKUtilities
import PKTestSupport
@testable import PositronicKit
import Testing

/// Regression coverage for the `dryRun` contract on `pruneMessages` / `pruneThreads` /
/// `pruneMemories`: `dryRun: true` must never mutate persisted state (PKAPI-013).
///
/// The in-memory `MessageStoreProtocol` / `ThreadPersistenceProtocol` / `MemoryStoreProtocol`
/// conformers shipped from this package (the stub `InMemory*` stores and `PKTestSupport`'s
/// `Mock*` stores) currently implement `prune*` as unconditional no-ops that always return `0`.
/// That trivially satisfies "dry run never deletes," but these tests pin the behavior down
/// explicitly so a future real implementation (or a stub that starts actually deleting rows)
/// can't silently violate the dry-run contract.
@Suite("Prune dryRun contract")
struct PruneDryRunTests {
    @Test("MockMessageStore: pruneMessages(dryRun: true) does not delete messages")
    func mockMessageStoreDryRunPreservesMessages() async throws {
        let store = MockMessageStore()
        let threadID = UUID()
        let message = ConversationMessage(
            threadID: threadID,
            role: .user,
            content: "hello",
            timestamp: Date(timeIntervalSince1970: 0)
        )
        try await store.saveMessage(message)

        _ = try await store.pruneMessages(olderThan: 0, dryRun: true)

        let remaining = try await store.fetchMessages(for: threadID)
        #expect(remaining.count == 1)
    }

    @Test("InMemoryMessageStore: pruneMessages(dryRun: true) does not delete messages")
    func inMemoryMessageStoreDryRunPreservesMessages() async throws {
        let store = InMemoryMessageStore()
        let threadID = UUID()
        let message = ConversationMessage(
            threadID: threadID,
            role: .user,
            content: "hello",
            timestamp: Date(timeIntervalSince1970: 0)
        )
        try await store.saveMessage(message)

        _ = try await store.pruneMessages(olderThan: 0, dryRun: true)

        let remaining = try await store.fetchMessages(for: threadID)
        #expect(remaining.count == 1)
    }

    @Test("MockThreadPersistence: pruneThreads(dryRun: true) does not delete threads")
    func mockThreadPersistenceDryRunPreservesThreads() async throws {
        let store = MockThreadPersistence()
        let thread = Thread(createdAt: Date(timeIntervalSince1970: 0))
        try await store.saveThread(thread)

        _ = try await store.pruneThreads(olderThan: 0, excluding: [], dryRun: true)

        let remaining = try await store.fetchThread(id: thread.id)
        #expect(remaining != nil)
    }

    @Test("InMemoryThreadPersistence: pruneThreads(dryRun: true) does not delete threads")
    func inMemoryThreadPersistenceDryRunPreservesThreads() async throws {
        let store = InMemoryThreadPersistence()
        let thread = Thread(createdAt: Date(timeIntervalSince1970: 0))
        try await store.saveThread(thread)

        _ = try await store.pruneThreads(olderThan: 0, excluding: [], dryRun: true)

        let remaining = try await store.fetchThread(id: thread.id)
        #expect(remaining != nil)
    }

    @Test("MockMemoryStore: pruneMemories(matching:dryRun:) does not delete memories")
    func mockMemoryStoreDryRunMatchingPreservesMemories() async throws {
        let store = MockMemoryStore()
        let memory = Memory.fixture(title: "Old Memory")
        _ = try await store.saveMemory(memory, policy: .immediate)

        _ = try await store.pruneMemories(matching: "Old", dryRun: true)

        let remaining = try await store.fetchMemory(id: memory.id)
        #expect(remaining != nil)
    }

    @Test("MockMemoryStore: pruneMemories(olderThan:dryRun:) does not delete memories")
    func mockMemoryStoreDryRunOlderThanPreservesMemories() async throws {
        let store = MockMemoryStore()
        let memory = Memory.fixture(timestamp: Date(timeIntervalSince1970: 0))
        _ = try await store.saveMemory(memory, policy: .immediate)

        _ = try await store.pruneMemories(olderThan: 0, dryRun: true)

        let remaining = try await store.fetchMemory(id: memory.id)
        #expect(remaining != nil)
    }

    @Test("InMemoryMemoryStore: pruneMemories(matching:dryRun:) does not delete memories")
    func inMemoryMemoryStoreDryRunMatchingPreservesMemories() async throws {
        let store = InMemoryMemoryStore()
        let memory = Memory.fixture(title: "Old Memory")
        _ = try await store.saveMemory(memory, policy: .immediate)

        _ = try await store.pruneMemories(matching: "Old", dryRun: true)

        let remaining = try await store.fetchMemory(id: memory.id)
        #expect(remaining != nil)
    }

    @Test("InMemoryMemoryStore: pruneMemories(olderThan:dryRun:) does not delete memories")
    func inMemoryMemoryStoreDryRunOlderThanPreservesMemories() async throws {
        let store = InMemoryMemoryStore()
        let memory = Memory.fixture(timestamp: Date(timeIntervalSince1970: 0))
        _ = try await store.saveMemory(memory, policy: .immediate)

        _ = try await store.pruneMemories(olderThan: 0, dryRun: true)

        let remaining = try await store.fetchMemory(id: memory.id)
        #expect(remaining != nil)
    }
}
