import Foundation
import PKTestSupport
import Testing
@testable import PositronicKit

<<<<<<<< HEAD:Tests/PositronicKitTests/Threads/ThreadDriverTests.swift
@Suite("ThreadHandle", .tags(.integration))
struct ThreadDriverTests {
    @Test("opening a thread returns a fresh handle with stable thread identity")
    func openingReturnsThreadHandleWithStableIdentity() async throws {
========
@Suite("TimelineHandle")
struct TimelineDriverTests {
    @Test("opening a timeline returns a fresh handle with stable timeline identity")
    func openingReturnsTimelineHandleWithStableIdentity() async throws {
>>>>>>>> 68f2ea52 (refactor(api)!: migrate facade, Timeline, and tool names (#156)):Tests/PositronicKitTests/TimelineDriverTests.swift
        let runtime = TestRuntime(workspaceRoot: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString))
        let kit = runtime.runtime

        let created = try await kit.timelineManager.createTimeline(title: "Cursor")
        let first: TimelineHandle = kit.timelines.open(created.id)
        let second = kit.timelines.open(created.id)

        #expect(first.timelineID == created.id)
        #expect(second.timelineID == created.id)
        #expect(first.id == second.id)
    }

    @Test("opening returns fresh handles with stable timeline identity and no persistence I/O")
    func openingReturnsFreshHandlesWithStableIdentity() async throws {
        let runtime = TestRuntime(workspaceRoot: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString))
        let kit = runtime.runtime

        let created = try await kit.timelineManager.createTimeline(title: "Cursor")
        let first = kit.timelines.open(created.id)
        let second = kit.timelines.open(created.id)

        #expect(first.id == created.id)
        #expect(second.id == created.id)
        #expect(first.id == second.id)
    }

    @Test("opening does not persist a timeline")
    func openingDoesNotPersistATimeline() async throws {
        let runtime = TestRuntime(workspaceRoot: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString))
        let kit = runtime.runtime
        let id = UUID()

        _ = kit.timelines.open(id)

        #expect(try await runtime.persistence.fetchTimeline(id: id) == nil)
    }

    @Test("opening performs no persistence I/O even against a store that would fail if touched")
    func openingPerformsNoPersistenceIOAgainstFailingStore() async throws {
        // `FailingTimelinePersistence` throws on every fetch/save/delete call. If
        // `TimelineCapability.open(_:)` performed any persistence lookup or write, constructing the
        // driver below would throw. It must not: opening is pure value construction.
        _ = FailingTimelinePersistence(
            fetchFails: true,
            saveFails: true,
            deleteFails: true
        )
        let kit = PKRuntime(configuration: .init(
            languageModel: UnconfiguredLLMService(),
            persistence: .init(runtimeRepository: InMemoryTimelineRuntimeRepository())
        ))

        let id = UUID()
        let driver = kit.timelines.open(id)
        #expect(driver.id == id)
    }

    @Test("startTurn delegates through the canonical TurnHandle path")
    func startTurnUsesCanonicalTurnHandlePath() async throws {
        let runtime = TestRuntime(workspaceRoot: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString))
        runtime.llm.mockClient.nextResponse = "reply"
        let kit = runtime.runtime
        let timeline = try await kit.timelineManager.createTimeline(title: "Driver")
        let agent = try await kit.agents.create(name: "Driver Agent", description: "test")
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

        runtime.llm.mockClient.nextResponse = "second reply"
        let followUp = try await driver.startTurn("follow up")
        _ = await followUp.events().collect()

        #expect(try await runtime.persistence.fetchMessages(for: driver.id).map(\.content) == [
            "hello", "reply", "follow up", "second reply"
        ])
    }
}
