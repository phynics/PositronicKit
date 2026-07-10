import Foundation
import PKTestSupport
import Testing
@testable import PositronicKit

@Suite("Conversation cursor")
struct ConversationTests {
    @Test("vending returns fresh handles with stable timeline identity")
    func vendingReturnsFreshHandlesWithStableIdentity() async throws {
        let runtime = TestRuntime(workspaceRoot: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString))
        let kit = runtime.buildCore()

        let created = try await kit.newConversation(title: "Cursor")
        let first = kit.conversation(timelineId: created.id)
        let second = kit.conversation(timelineId: created.id)

        #expect(first.id == created.id)
        #expect(second.id == created.id)
        #expect(first.id == second.id)
        #expect(first.timelineManager === second.timelineManager)
    }

    @Test("lookup does not persist a timeline")
    func lookupDoesNotPersistATimeline() async throws {
        let runtime = TestRuntime(workspaceRoot: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString))
        let kit = runtime.buildCore()
        let id = UUID()

        _ = kit.conversation(timelineId: id)

        #expect(try await runtime.persistence.fetchTimeline(id: id) == nil)
    }

    @Test("send delegates through the facade run path")
    func sendDelegatesThroughFacadeRunPath() async throws {
        let runtime = TestRuntime(workspaceRoot: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString))
        runtime.llm.mockClient.nextResponse = "reply"
        let kit = runtime.buildCore()
        let conversation = try await kit.newConversation()

        let events = try await conversation.send("hello").collect()

        #expect(events.contains(where: {
            if case let .completion(.generationCompleted(message, _)) = $0 {
                return message.content == "reply"
            }
            return false
        }))

        runtime.llm.mockClient.nextResponse = "second reply"
        _ = try await conversation.send("follow up").collect()

        #expect(try await runtime.persistence.fetchMessages(for: conversation.id).map(\.content) == [
            "hello", "reply", "follow up", "second reply"
        ])
    }
}
