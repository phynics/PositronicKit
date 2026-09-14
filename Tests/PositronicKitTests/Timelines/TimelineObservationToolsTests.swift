import Foundation
@testable import PKContracts
import PKUtilities
@testable import PositronicKit
import Testing

/// Direct coverage for the cross-timeline observation tools (`thread_peek`,
/// `thread_list`).
///
/// These tools let an agent read/list *other* timelines without attaching to them. They
/// previously had only ~11–17% coverage — exercised transitively through the full
/// `RuntimeToolPolicyFactory` tool set, which left their parameter validation, privacy
/// guards, and message-limit clamping unverified. These tests drive each tool directly
/// against in-memory stores.
@Suite("Timeline observation tools", .tags(.integration))
struct TimelineObservationToolsTests {

    @Test("canonical observation tools preserve timeline call names")
    func canonicalObservationToolsPreserveCallNames() async throws {
        let timelineStore = InMemoryTimelinePersistence()
        let messageStore = InMemoryMessageStore()
        let timeline = TimelineRecord(title: "Canonical Observation")
        try await timelineStore.saveTimeline(timeline)

        let listTool = TimelineListTool(timelineStore: timelineStore)
        let peekTool = TimelinePeekTool(messageStore: messageStore, timelineStore: timelineStore)

        #expect(listTool.callName == "thread_list")
        #expect(peekTool.callName == "thread_peek")
        #expect((try await listTool.execute(parameters: [:])).isSuccess)
    }

    // MARK: - TimelinePeekTool

    @Suite("TimelinePeekTool", .tags(.integration))
    struct PeekToolTests {
        private func makeStores() -> (InMemoryTimelinePersistence, InMemoryMessageStore) {
            (InMemoryTimelinePersistence(), InMemoryMessageStore())
        }

        @Test("Returns recent messages from a non-private timeline")
        func returnsRecentMessages() async throws {
            let (timelineStore, messageStore) = makeStores()
            let timeline = TimelineRecord(title: "Public Chat")
            try await timelineStore.saveTimeline(timeline)
            try await messageStore.saveMessage(TimelineMessage(
                timelineID: timeline.id, role: .user, content: "Hello"
            ))
            try await messageStore.saveMessage(TimelineMessage(
                timelineID: timeline.id, role: .assistant, content: "Hi there"
            ))

            let tool = TimelinePeekTool(messageStore: messageStore, timelineStore: timelineStore)
            let result = try await tool.execute(parameters: [
                "thread_id": AnyCodable(timeline.id.uuidString),
            ])

            #expect(result.isSuccess)
            #expect(result.output.contains("Hello") == true)
            #expect(result.output.contains("Hi there") == true)
            #expect(result.output.contains("2 messages") == true)
        }

        @Test("Respects the limit parameter, clamped to 50")
        func respectsLimitClampedTo50() async throws {
            let (timelineStore, messageStore) = makeStores()
            let timeline = TimelineRecord(title: "Busy")
            try await timelineStore.saveTimeline(timeline)
            for i in 0..<60 {
                try await messageStore.saveMessage(TimelineMessage(
                    timelineID: timeline.id, role: .user, content: "msg \(i)"
                ))
            }

            let tool = TimelinePeekTool(messageStore: messageStore, timelineStore: timelineStore)
            // Request 100, should be clamped to 50.
            let result = try await tool.execute(parameters: [
                "thread_id": AnyCodable(timeline.id.uuidString),
                "limit": AnyCodable(100),
            ])

            #expect(result.isSuccess)
            #expect(result.output.contains("50 messages") == true)
        }

        @Test("Rejects a negative limit without trapping")
        func negativeLimitFailsWithoutTrap() async throws {
            let (timelineStore, messageStore) = makeStores()
            let timeline = TimelineRecord(title: "Negative Limit")
            try await timelineStore.saveTimeline(timeline)
            try await messageStore.saveMessage(TimelineMessage(
                timelineID: timeline.id, role: .user, content: "message"
            ))

            let tool = TimelinePeekTool(messageStore: messageStore, timelineStore: timelineStore)
            let result = try await tool.execute(parameters: [
                "thread_id": AnyCodable(timeline.id.uuidString),
                "limit": AnyCodable(-1),
            ])

            #expect(!result.isSuccess)
            #expect(result.error?.contains("non-negative") == true)
        }

        @Test("Uses a default limit of 10 when omitted")
        func defaultLimitIs10() async throws {
            let (timelineStore, messageStore) = makeStores()
            let timeline = TimelineRecord(title: "Default")
            try await timelineStore.saveTimeline(timeline)
            for i in 0..<15 {
                try await messageStore.saveMessage(TimelineMessage(
                    timelineID: timeline.id, role: .user, content: "msg \(i)"
                ))
            }

            let tool = TimelinePeekTool(messageStore: messageStore, timelineStore: timelineStore)
            let result = try await tool.execute(parameters: [
                "thread_id": AnyCodable(timeline.id.uuidString),
            ])

            #expect(result.isSuccess)
            #expect(result.output.contains("10 messages") == true)
        }

        @Test("Refuses to peek at a private timeline")
        func refusesPrivateTimeline() async throws {
            let (timelineStore, messageStore) = makeStores()
            let timeline = TimelineRecord(title: "Secret", isPrivate: true)
            try await timelineStore.saveTimeline(timeline)

            let tool = TimelinePeekTool(messageStore: messageStore, timelineStore: timelineStore)
            let result = try await tool.execute(parameters: [
                "thread_id": AnyCodable(timeline.id.uuidString),
            ])

            #expect(!result.isSuccess)
            #expect(result.error?.contains("private") == true)
        }

        @Test("Fails gracefully for an unknown timeline id")
        func unknownTimelineFails() async throws {
            let (timelineStore, messageStore) = makeStores()

            let tool = TimelinePeekTool(messageStore: messageStore, timelineStore: timelineStore)
            let result = try await tool.execute(parameters: [
                "thread_id": AnyCodable(UUID().uuidString),
            ])

            #expect(!result.isSuccess)
            #expect(result.error?.contains("not found") == true)
        }

        @Test("Fails for an invalid UUID string")
        func invalidUUIDFails() async throws {
            let (timelineStore, messageStore) = makeStores()

            let tool = TimelinePeekTool(messageStore: messageStore, timelineStore: timelineStore)
            let result = try await tool.execute(parameters: [
                "thread_id": AnyCodable("not-a-uuid"),
            ])

            #expect(!result.isSuccess)
            #expect(result.error?.contains("Invalid") == true)
        }

        @Test("Fails when timeline_id parameter is missing")
        func missingParameterFails() async throws {
            let (timelineStore, messageStore) = makeStores()

            let tool = TimelinePeekTool(messageStore: messageStore, timelineStore: timelineStore)
            let result = try await tool.execute(parameters: [:])

            #expect(!result.isSuccess)
        }

        @Test("canExecute always returns true")
        func canExecuteIsTrue() async throws {
            let (timelineStore, messageStore) = makeStores()
            let tool = TimelinePeekTool(messageStore: messageStore, timelineStore: timelineStore)
            #expect(await tool.canExecute() == true)
        }

        @Test("Returns zero messages for an empty timeline")
        func emptyTimelineReturnsZero() async throws {
            let (timelineStore, messageStore) = makeStores()
            let timeline = TimelineRecord(title: "Empty")
            try await timelineStore.saveTimeline(timeline)

            let tool = TimelinePeekTool(messageStore: messageStore, timelineStore: timelineStore)
            let result = try await tool.execute(parameters: [
                "thread_id": AnyCodable(timeline.id.uuidString),
            ])

            #expect(result.isSuccess)
            #expect(result.output.contains("0 messages") == true)
        }
    }

    // MARK: - TimelineListTool

    @Suite("TimelineListTool", .tags(.integration))
    struct ListToolTests {
        @Test("Lists only non-private, non-archived timelines")
        func listsNonPrivateNonArchived() async throws {
            let timelineStore = InMemoryTimelinePersistence()
            let public1 = TimelineRecord(title: "Public One")
            let public2 = TimelineRecord(title: "Public Two", attachedAgentID: UUID())
            let private1 = TimelineRecord(title: "Private", isPrivate: true)
            let archived1 = TimelineRecord(title: "Archived", isArchived: true)
            for t in [public1, public2, private1, archived1] {
                try await timelineStore.saveTimeline(t)
            }

            let tool = TimelineListTool(timelineStore: timelineStore)
            let result = try await tool.execute(parameters: [:])

            #expect(result.isSuccess)
            let output = result.output
            #expect(output.contains(public1.id.uuidString))
            #expect(output.contains(public2.id.uuidString))
            #expect(!output.contains(private1.id.uuidString))
            #expect(!output.contains(archived1.id.uuidString))
        }

        @Test("Includes the attached agent id when present")
        func includesAttachedAgentId() async throws {
            let timelineStore = InMemoryTimelinePersistence()
            let agentId = UUID()
            let timeline = TimelineRecord(title: "With Agent", attachedAgentID: agentId)
            try await timelineStore.saveTimeline(timeline)

            let tool = TimelineListTool(timelineStore: timelineStore)
            let result = try await tool.execute(parameters: [:])

            #expect(result.isSuccess)
            #expect(result.output.contains(agentId.uuidString) == true)
        }

        @Test("Returns empty list when no timelines exist")
        func emptyWhenNoTimelines() async throws {
            let timelineStore = InMemoryTimelinePersistence()

            let tool = TimelineListTool(timelineStore: timelineStore)
            let result = try await tool.execute(parameters: [:])

            #expect(result.isSuccess)
            #expect(result.output.contains("[]") == true)
        }

        @Test("Excludes archived timelines even if non-private")
        func excludesArchived() async throws {
            let timelineStore = InMemoryTimelinePersistence()
            let archived = TimelineRecord(title: "Old", isArchived: true)
            try await timelineStore.saveTimeline(archived)

            let tool = TimelineListTool(timelineStore: timelineStore)
            let result = try await tool.execute(parameters: [:])

            #expect(result.isSuccess)
            #expect(result.output.contains("[]") == true)
        }

        @Test("canExecute always returns true")
        func canExecuteIsTrue() async throws {
            let tool = TimelineListTool(timelineStore: InMemoryTimelinePersistence())
            #expect(await tool.canExecute() == true)
        }
    }
}
