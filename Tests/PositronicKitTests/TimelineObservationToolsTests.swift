import Foundation
@testable import PKShared
import PKUtilities
@testable import PositronicKit
import Testing

/// Direct coverage for the cross-timeline observation tools (`timeline_peek`,
/// `timeline_list`).
///
/// These tools let an agent read/list *other* timelines without attaching to them. They
/// previously had only ~11–17% coverage — exercised transitively through the full
/// `RuntimeToolPolicyFactory` tool set, which left their parameter validation, privacy
/// guards, and message-limit clamping unverified. These tests drive each tool directly
/// against in-memory stores.
@Suite("Timeline observation tools")
struct TimelineObservationToolsTests {

    // MARK: - TimelinePeekTool

    @Suite("TimelinePeekTool")
    struct PeekToolTests {
        private func makeStores() -> (InMemoryTimelinePersistence, InMemoryMessageStore) {
            (InMemoryTimelinePersistence(), InMemoryMessageStore())
        }

        @Test("Returns recent messages from a non-private timeline")
        func returnsRecentMessages() async throws {
            let (timelineStore, messageStore) = makeStores()
            let timeline = Timeline(title: "Public Chat")
            try await timelineStore.saveTimeline(timeline)
            try await messageStore.saveMessage(ConversationMessage(
                timelineId: timeline.id, role: .user, content: "Hello"
            ))
            try await messageStore.saveMessage(ConversationMessage(
                timelineId: timeline.id, role: .assistant, content: "Hi there"
            ))

            let tool = TimelinePeekTool(messageStore: messageStore, timelineStore: timelineStore)
            let result = try await tool.execute(parameters: [
                "timeline_id": AnyCodable(timeline.id.uuidString),
            ])

            #expect(result.success)
            #expect(result.output.contains("Hello") == true)
            #expect(result.output.contains("Hi there") == true)
            #expect(result.output.contains("2 messages") == true)
        }

        @Test("Respects the limit parameter, clamped to 50")
        func respectsLimitClampedTo50() async throws {
            let (timelineStore, messageStore) = makeStores()
            let timeline = Timeline(title: "Busy")
            try await timelineStore.saveTimeline(timeline)
            for i in 0..<60 {
                try await messageStore.saveMessage(ConversationMessage(
                    timelineId: timeline.id, role: .user, content: "msg \(i)"
                ))
            }

            let tool = TimelinePeekTool(messageStore: messageStore, timelineStore: timelineStore)
            // Request 100, should be clamped to 50.
            let result = try await tool.execute(parameters: [
                "timeline_id": AnyCodable(timeline.id.uuidString),
                "limit": AnyCodable(100),
            ])

            #expect(result.success)
            #expect(result.output.contains("50 messages") == true)
        }

        @Test("Uses a default limit of 10 when omitted")
        func defaultLimitIs10() async throws {
            let (timelineStore, messageStore) = makeStores()
            let timeline = Timeline(title: "Default")
            try await timelineStore.saveTimeline(timeline)
            for i in 0..<15 {
                try await messageStore.saveMessage(ConversationMessage(
                    timelineId: timeline.id, role: .user, content: "msg \(i)"
                ))
            }

            let tool = TimelinePeekTool(messageStore: messageStore, timelineStore: timelineStore)
            let result = try await tool.execute(parameters: [
                "timeline_id": AnyCodable(timeline.id.uuidString),
            ])

            #expect(result.success)
            #expect(result.output.contains("10 messages") == true)
        }

        @Test("Refuses to peek at a private timeline")
        func refusesPrivateTimeline() async throws {
            let (timelineStore, messageStore) = makeStores()
            let timeline = Timeline(title: "Secret", isPrivate: true)
            try await timelineStore.saveTimeline(timeline)

            let tool = TimelinePeekTool(messageStore: messageStore, timelineStore: timelineStore)
            let result = try await tool.execute(parameters: [
                "timeline_id": AnyCodable(timeline.id.uuidString),
            ])

            #expect(!result.success)
            #expect(result.error?.contains("private") == true)
        }

        @Test("Fails gracefully for an unknown timeline id")
        func unknownTimelineFails() async throws {
            let (timelineStore, messageStore) = makeStores()

            let tool = TimelinePeekTool(messageStore: messageStore, timelineStore: timelineStore)
            let result = try await tool.execute(parameters: [
                "timeline_id": AnyCodable(UUID().uuidString),
            ])

            #expect(!result.success)
            #expect(result.error?.contains("not found") == true)
        }

        @Test("Fails for an invalid UUID string")
        func invalidUUIDFails() async throws {
            let (timelineStore, messageStore) = makeStores()

            let tool = TimelinePeekTool(messageStore: messageStore, timelineStore: timelineStore)
            let result = try await tool.execute(parameters: [
                "timeline_id": AnyCodable("not-a-uuid"),
            ])

            #expect(!result.success)
            #expect(result.error?.contains("Invalid") == true)
        }

        @Test("Fails when timeline_id parameter is missing")
        func missingParameterFails() async throws {
            let (timelineStore, messageStore) = makeStores()

            let tool = TimelinePeekTool(messageStore: messageStore, timelineStore: timelineStore)
            let result = try await tool.execute(parameters: [:])

            #expect(!result.success)
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
            let timeline = Timeline(title: "Empty")
            try await timelineStore.saveTimeline(timeline)

            let tool = TimelinePeekTool(messageStore: messageStore, timelineStore: timelineStore)
            let result = try await tool.execute(parameters: [
                "timeline_id": AnyCodable(timeline.id.uuidString),
            ])

            #expect(result.success)
            #expect(result.output.contains("0 messages") == true)
        }
    }

    // MARK: - TimelineListTool

    @Suite("TimelineListTool")
    struct ListToolTests {
        @Test("Lists only non-private, non-archived timelines")
        func listsNonPrivateNonArchived() async throws {
            let timelineStore = InMemoryTimelinePersistence()
            let public1 = Timeline(title: "Public One")
            let public2 = Timeline(title: "Public Two", attachedAgentInstanceId: UUID())
            let private1 = Timeline(title: "Private", isPrivate: true)
            let archived1 = Timeline(title: "Archived", isArchived: true)
            for t in [public1, public2, private1, archived1] {
                try await timelineStore.saveTimeline(t)
            }

            let tool = TimelineListTool(timelineStore: timelineStore)
            let result = try await tool.execute(parameters: [:])

            #expect(result.success)
            let output = try #require(result.output)
            #expect(output.contains(public1.id.uuidString))
            #expect(output.contains(public2.id.uuidString))
            #expect(!output.contains(private1.id.uuidString))
            #expect(!output.contains(archived1.id.uuidString))
        }

        @Test("Includes the attached agent id when present")
        func includesAttachedAgentId() async throws {
            let timelineStore = InMemoryTimelinePersistence()
            let agentId = UUID()
            let timeline = Timeline(title: "With Agent", attachedAgentInstanceId: agentId)
            try await timelineStore.saveTimeline(timeline)

            let tool = TimelineListTool(timelineStore: timelineStore)
            let result = try await tool.execute(parameters: [:])

            #expect(result.success)
            #expect(result.output.contains(agentId.uuidString) == true)
        }

        @Test("Returns empty list when no timelines exist")
        func emptyWhenNoTimelines() async throws {
            let timelineStore = InMemoryTimelinePersistence()

            let tool = TimelineListTool(timelineStore: timelineStore)
            let result = try await tool.execute(parameters: [:])

            #expect(result.success)
            #expect(result.output.contains("[]") == true)
        }

        @Test("Excludes archived timelines even if non-private")
        func excludesArchived() async throws {
            let timelineStore = InMemoryTimelinePersistence()
            let archived = Timeline(title: "Old", isArchived: true)
            try await timelineStore.saveTimeline(archived)

            let tool = TimelineListTool(timelineStore: timelineStore)
            let result = try await tool.execute(parameters: [:])

            #expect(result.success)
            #expect(result.output.contains("[]") == true)
        }

        @Test("canExecute always returns true")
        func canExecuteIsTrue() async throws {
            let tool = TimelineListTool(timelineStore: InMemoryTimelinePersistence())
            #expect(await tool.canExecute() == true)
        }
    }
}
