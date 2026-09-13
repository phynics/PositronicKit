import Foundation
import PKContracts
import PKUtilities
import PKTestSupport
@testable import PositronicKit
import Testing

/// PKRR-005 lifecycle invariants: `TimelineCapability.open(_:)` opens an existing timeline only. Sending
/// to a missing ID throws before any user input is persisted. Store failure is
/// distinguishable from not-found.
<<<<<<<< HEAD:Tests/PositronicKitTests/Threads/ThreadLifecycleInvariantTests.swift
@Suite("Thread lifecycle invariants (PKRR-005)", .tags(.integration))
struct ThreadLifecycleInvariantTests {
    @Test("Sending to a never-created thread throws threadNotFound before persisting")
    func sendToMissingThreadThrowsBeforePersisting() async throws {
========
@Suite("Timeline lifecycle invariants (PKRR-005)")
struct TimelineLifecycleInvariantTests {
    @Test("Sending to a never-created timeline throws timelineNotFound before persisting")
    func sendToMissingTimelineThrowsBeforePersisting() async throws {
>>>>>>>> 68f2ea52 (refactor(api)!: migrate facade, Timeline, and tool names (#156)):Tests/PositronicKitTests/TimelineLifecycleInvariantTests.swift
        let mockLLM = MockLLMService()
        let mockPersistence = MockPersistenceService()
        let kit = PKRuntime(configuration: .init(
            languageModel: mockLLM,
            persistence: .init(
                runtimeRepository: mockPersistence,
                workspacePersistence: mockPersistence,
                toolPersistence: mockPersistence,
                agentStore: mockPersistence,
                requestOriginStore: mockPersistence
            )
        ))

        let missingId = UUID()

        await #expect(throws: TimelineError.timelineNotFound) {
            _ = try await kit.run(TurnRequest(
                timelineID: missingId,
                message: "should not be persisted"
            ))
        }

        let messages = try await mockPersistence.fetchMessages(for: missingId)
        #expect(messages.isEmpty, "No user input should be persisted when the timeline does not exist")
    }

    @Test("Store failure during hydration throws unavailable and no message is persisted")
    func storeFailureThrowsUnavailableBeforePersisting() async throws {
        let mockLLM = MockLLMService()
        let mockMessages = MockPersistenceService()
        mockMessages.fetchTimelineFails = true
        let kit = PKRuntime(configuration: .init(
            languageModel: mockLLM,
            persistence: .init(
                runtimeRepository: mockMessages,
                workspacePersistence: mockMessages,
                toolPersistence: mockMessages,
                agentStore: mockMessages,
                requestOriginStore: mockMessages
            )
        ))

        let unresolvedId = UUID()

        await #expect(throws: TimelineError.unavailable) {
            _ = try await kit.run(TurnRequest(
                timelineID: unresolvedId,
                message: "should not be persisted"
            ))
        }

        let messages = try await mockMessages.fetchMessages(for: unresolvedId)
        #expect(messages.isEmpty, "No user input should be persisted when the store is unavailable")
    }

    @Test("TimelineHandle.startTurn to a missing timeline throws timelineNotFound")
    func startTurnToMissingTimelineThrows() async throws {
        let mockLLM = MockLLMService()
        let kit = PKRuntime(configuration: .init(
            languageModel: mockLLM,
            persistence: .inMemory()
        ))

        let driver = kit.timelines.open(UUID())

        await #expect(throws: TimelineError.timelineNotFound) {
            _ = try await driver.startTurn("hello")
        }
    }

    @Test("A created timeline accepts sends normally")
    func createdTimelineAcceptsSends() async throws {
        let runtime = TestRuntime(workspaceRoot: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString))
        runtime.llm.mockClient.nextResponse = "reply"
        let kit = runtime.runtime
        let timeline = try await kit.timelineManager.createTimeline(title: "Lifecycle Invariant")
        let agent = try await kit.agents.create(name: "Lifecycle Agent", description: "test")
        try await kit.agents.attach(agent.id, to: timeline.id)
        let driver = kit.timelines.open(timeline.id)

        let turn = try await driver.startTurn("hello")
        let events = await turn.events().collect()

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
        let kit = runtime.runtime
        let timeline = try await kit.timelineManager.createTimeline(title: "Hydrated")

        // Should not throw — the timeline is already in cache from createTimeline.
        try await kit.timelineManager.ensureTimelineExists(id: timeline.id)
    }

    @Test("ensureTimelineExists throws timelineNotFound for an unknown ID")
    func ensureTimelineExistsThrowsForUnknown() async throws {
        let runtime = TestRuntime(workspaceRoot: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString))
        let kit = runtime.runtime

        await #expect(throws: TimelineError.timelineNotFound) {
            try await kit.timelineManager.ensureTimelineExists(id: UUID())
        }
    }
}
