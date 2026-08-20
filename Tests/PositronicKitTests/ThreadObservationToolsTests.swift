import Foundation
@testable import PKContracts
import PKUtilities
@testable import PositronicKit
import Testing

/// Direct coverage for the cross-thread observation tools (`thread_peek`,
/// `thread_list`).
///
/// These tools let an agent read/list *other* threads without attaching to them. They
/// previously had only ~11–17% coverage — exercised transitively through the full
/// `RuntimeToolPolicyFactory` tool set, which left their parameter validation, privacy
/// guards, and message-limit clamping unverified. These tests drive each tool directly
/// against in-memory stores.
@Suite("Thread observation tools")
struct ThreadObservationToolsTests {

    @Test("canonical observation tools preserve thread call names")
    func canonicalObservationToolsPreserveCallNames() async throws {
        let threadStore = InMemoryThreadPersistence()
        let messageStore = InMemoryMessageStore()
        let thread = Thread(title: "Canonical Observation")
        try await threadStore.saveThread(thread)

        let listTool = ThreadListTool(threadStore: threadStore)
        let peekTool = ThreadPeekTool(messageStore: messageStore, threadStore: threadStore)

        #expect(listTool.callName == "thread_list")
        #expect(peekTool.callName == "thread_peek")
        #expect((try await listTool.execute(parameters: [:])).success)
    }

    // MARK: - ThreadPeekTool

    @Suite("ThreadPeekTool")
    struct PeekToolTests {
        private func makeStores() -> (InMemoryThreadPersistence, InMemoryMessageStore) {
            (InMemoryThreadPersistence(), InMemoryMessageStore())
        }

        @Test("Returns recent messages from a non-private thread")
        func returnsRecentMessages() async throws {
            let (threadStore, messageStore) = makeStores()
            let thread = Thread(title: "Public Chat")
            try await threadStore.saveThread(thread)
            try await messageStore.saveMessage(ThreadMessage(
                threadID: thread.id, role: .user, content: "Hello"
            ))
            try await messageStore.saveMessage(ThreadMessage(
                threadID: thread.id, role: .assistant, content: "Hi there"
            ))

            let tool = ThreadPeekTool(messageStore: messageStore, threadStore: threadStore)
            let result = try await tool.execute(parameters: [
                "thread_id": AnyCodable(thread.id.uuidString),
            ])

            #expect(result.success)
            #expect(result.output.contains("Hello") == true)
            #expect(result.output.contains("Hi there") == true)
            #expect(result.output.contains("2 messages") == true)
        }

        @Test("Respects the limit parameter, clamped to 50")
        func respectsLimitClampedTo50() async throws {
            let (threadStore, messageStore) = makeStores()
            let thread = Thread(title: "Busy")
            try await threadStore.saveThread(thread)
            for i in 0..<60 {
                try await messageStore.saveMessage(ThreadMessage(
                    threadID: thread.id, role: .user, content: "msg \(i)"
                ))
            }

            let tool = ThreadPeekTool(messageStore: messageStore, threadStore: threadStore)
            // Request 100, should be clamped to 50.
            let result = try await tool.execute(parameters: [
                "thread_id": AnyCodable(thread.id.uuidString),
                "limit": AnyCodable(100),
            ])

            #expect(result.success)
            #expect(result.output.contains("50 messages") == true)
        }

        @Test("Rejects a negative limit without trapping")
        func negativeLimitFailsWithoutTrap() async throws {
            let (threadStore, messageStore) = makeStores()
            let thread = Thread(title: "Negative Limit")
            try await threadStore.saveThread(thread)
            try await messageStore.saveMessage(ThreadMessage(
                threadID: thread.id, role: .user, content: "message"
            ))

            let tool = ThreadPeekTool(messageStore: messageStore, threadStore: threadStore)
            let result = try await tool.execute(parameters: [
                "thread_id": AnyCodable(thread.id.uuidString),
                "limit": AnyCodable(-1),
            ])

            #expect(!result.success)
            #expect(result.error?.contains("non-negative") == true)
        }

        @Test("Uses a default limit of 10 when omitted")
        func defaultLimitIs10() async throws {
            let (threadStore, messageStore) = makeStores()
            let thread = Thread(title: "Default")
            try await threadStore.saveThread(thread)
            for i in 0..<15 {
                try await messageStore.saveMessage(ThreadMessage(
                    threadID: thread.id, role: .user, content: "msg \(i)"
                ))
            }

            let tool = ThreadPeekTool(messageStore: messageStore, threadStore: threadStore)
            let result = try await tool.execute(parameters: [
                "thread_id": AnyCodable(thread.id.uuidString),
            ])

            #expect(result.success)
            #expect(result.output.contains("10 messages") == true)
        }

        @Test("Refuses to peek at a private thread")
        func refusesPrivateThread() async throws {
            let (threadStore, messageStore) = makeStores()
            let thread = Thread(title: "Secret", isPrivate: true)
            try await threadStore.saveThread(thread)

            let tool = ThreadPeekTool(messageStore: messageStore, threadStore: threadStore)
            let result = try await tool.execute(parameters: [
                "thread_id": AnyCodable(thread.id.uuidString),
            ])

            #expect(!result.success)
            #expect(result.error?.contains("private") == true)
        }

        @Test("Fails gracefully for an unknown thread id")
        func unknownThreadFails() async throws {
            let (threadStore, messageStore) = makeStores()

            let tool = ThreadPeekTool(messageStore: messageStore, threadStore: threadStore)
            let result = try await tool.execute(parameters: [
                "thread_id": AnyCodable(UUID().uuidString),
            ])

            #expect(!result.success)
            #expect(result.error?.contains("not found") == true)
        }

        @Test("Fails for an invalid UUID string")
        func invalidUUIDFails() async throws {
            let (threadStore, messageStore) = makeStores()

            let tool = ThreadPeekTool(messageStore: messageStore, threadStore: threadStore)
            let result = try await tool.execute(parameters: [
                "thread_id": AnyCodable("not-a-uuid"),
            ])

            #expect(!result.success)
            #expect(result.error?.contains("Invalid") == true)
        }

        @Test("Fails when thread_id parameter is missing")
        func missingParameterFails() async throws {
            let (threadStore, messageStore) = makeStores()

            let tool = ThreadPeekTool(messageStore: messageStore, threadStore: threadStore)
            let result = try await tool.execute(parameters: [:])

            #expect(!result.success)
        }

        @Test("canExecute always returns true")
        func canExecuteIsTrue() async throws {
            let (threadStore, messageStore) = makeStores()
            let tool = ThreadPeekTool(messageStore: messageStore, threadStore: threadStore)
            #expect(await tool.canExecute() == true)
        }

        @Test("Returns zero messages for an empty thread")
        func emptyThreadReturnsZero() async throws {
            let (threadStore, messageStore) = makeStores()
            let thread = Thread(title: "Empty")
            try await threadStore.saveThread(thread)

            let tool = ThreadPeekTool(messageStore: messageStore, threadStore: threadStore)
            let result = try await tool.execute(parameters: [
                "thread_id": AnyCodable(thread.id.uuidString),
            ])

            #expect(result.success)
            #expect(result.output.contains("0 messages") == true)
        }
    }

    // MARK: - ThreadListTool

    @Suite("ThreadListTool")
    struct ListToolTests {
        @Test("Lists only non-private, non-archived threads")
        func listsNonPrivateNonArchived() async throws {
            let threadStore = InMemoryThreadPersistence()
            let public1 = Thread(title: "Public One")
            let public2 = Thread(title: "Public Two", attachedAgentID: UUID())
            let private1 = Thread(title: "Private", isPrivate: true)
            let archived1 = Thread(title: "Archived", isArchived: true)
            for t in [public1, public2, private1, archived1] {
                try await threadStore.saveThread(t)
            }

            let tool = ThreadListTool(threadStore: threadStore)
            let result = try await tool.execute(parameters: [:])

            #expect(result.success)
            let output = result.output
            #expect(output.contains(public1.id.uuidString))
            #expect(output.contains(public2.id.uuidString))
            #expect(!output.contains(private1.id.uuidString))
            #expect(!output.contains(archived1.id.uuidString))
        }

        @Test("Includes the attached agent id when present")
        func includesAttachedAgentId() async throws {
            let threadStore = InMemoryThreadPersistence()
            let agentId = UUID()
            let thread = Thread(title: "With Agent", attachedAgentID: agentId)
            try await threadStore.saveThread(thread)

            let tool = ThreadListTool(threadStore: threadStore)
            let result = try await tool.execute(parameters: [:])

            #expect(result.success)
            #expect(result.output.contains(agentId.uuidString) == true)
        }

        @Test("Returns empty list when no threads exist")
        func emptyWhenNoThreads() async throws {
            let threadStore = InMemoryThreadPersistence()

            let tool = ThreadListTool(threadStore: threadStore)
            let result = try await tool.execute(parameters: [:])

            #expect(result.success)
            #expect(result.output.contains("[]") == true)
        }

        @Test("Excludes archived threads even if non-private")
        func excludesArchived() async throws {
            let threadStore = InMemoryThreadPersistence()
            let archived = Thread(title: "Old", isArchived: true)
            try await threadStore.saveThread(archived)

            let tool = ThreadListTool(threadStore: threadStore)
            let result = try await tool.execute(parameters: [:])

            #expect(result.success)
            #expect(result.output.contains("[]") == true)
        }

        @Test("canExecute always returns true")
        func canExecuteIsTrue() async throws {
            let tool = ThreadListTool(threadStore: InMemoryThreadPersistence())
            #expect(await tool.canExecute() == true)
        }
    }
}
