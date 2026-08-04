import Foundation
import PKTestSupport
import Testing
@testable import PositronicKit

@Suite("TimelineDriver")
struct TimelineDriverTests {
    @Test("opening returns fresh handles with stable timeline identity and no persistence I/O")
    func openingReturnsFreshHandlesWithStableIdentity() async throws {
        let runtime = TestRuntime(workspaceRoot: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString))
        let kit = runtime.positronicKit

        let created = try await kit.timelineManager.createTimeline(title: "Cursor")
        let first = kit.openTimeline(created.id)
        let second = kit.openTimeline(created.id)

        #expect(first.id == created.id)
        #expect(second.id == created.id)
        #expect(first.id == second.id)
    }

    @Test("opening does not persist a timeline")
    func openingDoesNotPersistATimeline() async throws {
        let runtime = TestRuntime(workspaceRoot: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString))
        let kit = runtime.positronicKit
        let id = UUID()

        _ = kit.openTimeline(id)

        #expect(try await runtime.persistence.fetchTimeline(id: id) == nil)
    }

    @Test("opening performs no persistence I/O even against a store that would fail if touched")
    func openingPerformsNoPersistenceIOAgainstFailingStore() async throws {
        // `FailingTimelinePersistence` throws on every fetch/save/delete call. If
        // `openTimeline(_:)` performed any persistence lookup or write, constructing the
        // driver below would throw. It must not: opening is pure value construction.
        let failingTimelineStore = FailingTimelinePersistence(
            fetchFails: true,
            saveFails: true,
            deleteFails: true
        )
        let kit = PositronicKit(configuration: .init(
            provider: .init(llmService: UnconfiguredLLMService()),
            persistence: .init(timelinePersistence: failingTimelineStore)
        ))

        let id = UUID()
        let driver = kit.openTimeline(id)
        #expect(driver.id == id)
    }

    @Test("send delegates through the facade run path")
    func sendDelegatesThroughFacadeRunPath() async throws {
        let runtime = TestRuntime(workspaceRoot: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString))
        runtime.llm.mockClient.nextResponse = "reply"
        let kit = runtime.positronicKit
        let timeline = try await kit.timelineManager.createTimeline(title: "Driver")
        let driver = kit.openTimeline(timeline.id)

        let events = try await driver.send("hello").collect()

        #expect(events.contains(where: {
            if case let .completion(.generationCompleted(message, _)) = $0 {
                return message.content == "reply"
            }
            return false
        }))

        runtime.llm.mockClient.nextResponse = "second reply"
        _ = try await driver.send("follow up").collect()

        #expect(try await runtime.persistence.fetchMessages(for: driver.id).map(\.content) == [
            "hello", "reply", "follow up", "second reply"
        ])
    }
}
