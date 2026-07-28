import Foundation
import PKShared
import PKUtilities
import PKTestSupport
@testable import PositronicKit
import Testing

/// PKRR-005 lifecycle invariants: `openTimeline` opens an existing timeline only. Sending
/// to a missing ID throws before any user input is persisted. Store failure is
/// distinguishable from not-found.
@Suite("Timeline lifecycle invariants (PKRR-005)")
struct TimelineLifecycleInvariantTests {
    @Test("Sending to a never-created timeline throws timelineNotFound before persisting")
    func sendToMissingTimelineThrowsBeforePersisting() async throws {
        let mockLLM = MockLLMService()
        let mockPersistence = MockPersistenceService()
        let kit = PositronicKit(configuration: .init(
            provider: .init(llmService: mockLLM),
            persistence: .init(
                messageStore: mockPersistence,
                timelinePersistence: mockPersistence,
                workspacePersistence: mockPersistence,
                memoryStore: mockPersistence,
                toolPersistence: mockPersistence,
                agentInstanceStore: mockPersistence,
                requestOriginStore: mockPersistence
            )
        ))

        let missingId = UUID()

        await #expect(throws: TimelineError.timelineNotFound) {
            _ = try await kit.run(ChatRunRequest(
                timelineId: missingId,
                message: "should not be persisted"
            ))
        }

        let messages = try await mockPersistence.fetchMessages(for: missingId)
        #expect(messages.isEmpty, "No user input should be persisted when the timeline does not exist")
    }

    @Test("Store failure during hydration throws unavailable and no message is persisted")
    func storeFailureThrowsUnavailableBeforePersisting() async throws {
        let failingStore = FailingTimelinePersistence(fetchFails: true)
        let mockLLM = MockLLMService()
        let mockMessages = MockPersistenceService()
        let kit = PositronicKit(configuration: .init(
            provider: .init(llmService: mockLLM),
            persistence: .init(
                messageStore: mockMessages,
                timelinePersistence: failingStore,
                workspacePersistence: mockMessages,
                memoryStore: mockMessages,
                toolPersistence: mockMessages,
                agentInstanceStore: mockMessages,
                requestOriginStore: mockMessages
            )
        ))

        let unresolvedId = UUID()

        await #expect(throws: TimelineError.unavailable) {
            _ = try await kit.run(ChatRunRequest(
                timelineId: unresolvedId,
                message: "should not be persisted"
            ))
        }

        let messages = try await mockMessages.fetchMessages(for: unresolvedId)
        #expect(messages.isEmpty, "No user input should be persisted when the store is unavailable")
    }

    @Test("TimelineDriver.send to a missing timeline throws timelineNotFound")
    func driverSendToMissingTimelineThrows() async throws {
        let mockLLM = MockLLMService()
        let kit = PositronicKit(configuration: .init(
            provider: .init(llmService: mockLLM),
            persistence: .inMemory()
        ))

        let driver = kit.openTimeline(UUID())

        await #expect(throws: TimelineError.timelineNotFound) {
            _ = try await driver.send("hello").collect()
        }
    }

    @Test("A created timeline accepts sends normally")
    func createdTimelineAcceptsSends() async throws {
        let runtime = TestRuntime(workspaceRoot: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString))
        runtime.llm.mockClient.nextResponse = "reply"
        let kit = runtime.buildCore()
        let timeline = try await kit.timelineManager.createTimeline(title: "Lifecycle Invariant")
        let driver = kit.openTimeline(timeline.id)

        let events = try await driver.send("hello").collect()

        #expect(events.contains(where: {
            if case let .completion(.generationCompleted(message, _)) = $0 {
                return message.content == "reply"
            }
            return false
        }))

        let messages = try await runtime.persistence.fetchMessages(for: timeline.id).map(\.content)
        #expect(messages == ["hello", "reply"])
    }

    @Test("ensureTimelineExists is a no-op for an already-hydrated timeline")
    func ensureTimelineExistsNoOpForHydrated() async throws {
        let runtime = TestRuntime(workspaceRoot: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString))
        let kit = runtime.buildCore()
        let timeline = try await kit.timelineManager.createTimeline(title: "Hydrated")

        // Should not throw — the timeline is already in cache from createTimeline.
        try await kit.timelineManager.ensureTimelineExists(id: timeline.id)
    }

    @Test("ensureTimelineExists throws timelineNotFound for an unknown ID")
    func ensureTimelineExistsThrowsForUnknown() async throws {
        let runtime = TestRuntime(workspaceRoot: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString))
        let kit = runtime.buildCore()

        await #expect(throws: TimelineError.timelineNotFound) {
            try await kit.timelineManager.ensureTimelineExists(id: UUID())
        }
    }
}
