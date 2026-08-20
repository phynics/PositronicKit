import Foundation
import PKContracts
import PKUtilities
import PKTestSupport
@testable import PositronicKit
import Testing

/// PKRR-005 lifecycle invariants: `openThread` opens an existing thread only. Sending
/// to a missing ID throws before any user input is persisted. Store failure is
/// distinguishable from not-found.
@Suite("Thread lifecycle invariants (PKRR-005)")
struct ThreadLifecycleInvariantTests {
    @Test("Sending to a never-created thread throws threadNotFound before persisting")
    func sendToMissingThreadThrowsBeforePersisting() async throws {
        let mockLLM = MockLLMService()
        let mockPersistence = MockPersistenceService()
        let kit = PositronicKit(configuration: .init(
            provider: .init(languageModel: mockLLM),
            persistence: .init(
                messageStore: mockPersistence,
                threadPersistence: mockPersistence,
                workspacePersistence: mockPersistence,
                memoryStore: mockPersistence,
                toolPersistence: mockPersistence,
                agentStore: mockPersistence,
                requestOriginStore: mockPersistence
            )
        ))

        let missingId = UUID()

        await #expect(throws: ThreadError.threadNotFound) {
            _ = try await kit.run(TurnRequest(
                threadID: missingId,
                message: "should not be persisted"
            ))
        }

        let messages = try await mockPersistence.fetchMessages(for: missingId)
        #expect(messages.isEmpty, "No user input should be persisted when the thread does not exist")
    }

    @Test("Store failure during hydration throws unavailable and no message is persisted")
    func storeFailureThrowsUnavailableBeforePersisting() async throws {
        let failingStore = FailingThreadPersistence(fetchFails: true)
        let mockLLM = MockLLMService()
        let mockMessages = MockPersistenceService()
        let kit = PositronicKit(configuration: .init(
            provider: .init(languageModel: mockLLM),
            persistence: .init(
                messageStore: mockMessages,
                threadPersistence: failingStore,
                workspacePersistence: mockMessages,
                memoryStore: mockMessages,
                toolPersistence: mockMessages,
                agentStore: mockMessages,
                requestOriginStore: mockMessages
            )
        ))

        let unresolvedId = UUID()

        await #expect(throws: ThreadError.unavailable) {
            _ = try await kit.run(TurnRequest(
                threadID: unresolvedId,
                message: "should not be persisted"
            ))
        }

        let messages = try await mockMessages.fetchMessages(for: unresolvedId)
        #expect(messages.isEmpty, "No user input should be persisted when the store is unavailable")
    }

    @Test("ThreadDriver.send to a missing thread throws threadNotFound")
    func driverSendToMissingThreadThrows() async throws {
        let mockLLM = MockLLMService()
        let kit = PositronicKit(configuration: .init(
            provider: .init(languageModel: mockLLM),
            persistence: .inMemory()
        ))

        let driver = kit.openThread(UUID())

        await #expect(throws: ThreadError.threadNotFound) {
            _ = try await driver.send("hello").collect()
        }
    }

    @Test("A created thread accepts sends normally")
    func createdThreadAcceptsSends() async throws {
        let runtime = TestRuntime(workspaceRoot: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString))
        runtime.llm.mockClient.nextResponse = "reply"
        let kit = runtime.positronicKit
        let thread = try await kit.threadManager.createThread(title: "Lifecycle Invariant")
        let driver = kit.openThread(thread.id)

        let events = try await driver.send("hello").collect()

        #expect(events.contains(where: {
            if case let .completion(.generationCompleted(message, _)) = $0 {
                return message.content == "reply"
            }
            return false
        }))

        let messages = try await runtime.persistence.fetchMessages(for: thread.id).map(\.content)
        #expect(messages == ["hello", "reply"])
    }

    @Test("ensureThreadExists is a no-op for an already-hydrated thread")
    func ensureThreadExistsNoOpForHydrated() async throws {
        let runtime = TestRuntime(workspaceRoot: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString))
        let kit = runtime.positronicKit
        let thread = try await kit.threadManager.createThread(title: "Hydrated")

        // Should not throw — the thread is already in cache from createThread.
        try await kit.threadManager.ensureThreadExists(id: thread.id)
    }

    @Test("ensureThreadExists throws threadNotFound for an unknown ID")
    func ensureThreadExistsThrowsForUnknown() async throws {
        let runtime = TestRuntime(workspaceRoot: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString))
        let kit = runtime.positronicKit

        await #expect(throws: ThreadError.threadNotFound) {
            try await kit.threadManager.ensureThreadExists(id: UUID())
        }
    }
}
