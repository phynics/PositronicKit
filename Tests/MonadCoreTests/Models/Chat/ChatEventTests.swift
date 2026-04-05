import Testing
import MonadShared
import Foundation

@Suite final class ChatEventTests {

    @Test

    func testChatEventDelta() {
        let event = ChatEvent.delta(event: .generation(text: "Hello"))
        if case .delta(event: .generation(text: let text)) = event {
            #expect(text == "Hello")
        } else {
            Issue.record("Expected delta.generation")
        }
    }

    @Test

    func testChatEventThinking() {
        let event = ChatEvent.delta(event: .thinking(text: "Thinking..."))
        if case .delta(event: .thinking(text: let text)) = event {
            #expect(text == "Thinking...")
        } else {
            Issue.record("Expected delta.thinking")
        }
    }

    @Test

    func testChatEventToolCall() {
        let delta = ToolCallDelta(index: 0, id: "call1", name: "test", arguments: "{}")
        let event = ChatEvent.delta(event: .toolCall(delta: delta))
        if case .delta(event: .toolCall(delta: let tc)) = event {
            #expect(tc.id == "call1")
        } else {
            Issue.record("Expected delta.toolCall")
        }
    }

    @Test

    func testChatEventToolCallError() {
        let event = ChatEvent.error(event: .toolCallError(toolCallId: "call1", name: "test", error: "Not found"))
        if case .error(event: .toolCallError(let id, _, let error)) = event {
            #expect(id == "call1")
            #expect(error == "Not found")
        } else {
            Issue.record("Expected error.toolCallError")
        }
    }

    @Test

    func testChatEventToolExecution() {
        let ref = ToolReference.known("tool-1")
        let event = ChatEvent.delta(event: .toolExecution(toolCallId: "123", status: .attempting(name: "test", reference: ref)))
        if case .delta(event: .toolExecution(let id, _)) = event {
            #expect(id == "123")
        } else {
            Issue.record("Expected delta.toolExecution")
        }
    }

    @Test

    func testChatEventGenerationContext() {
        let metadata = ChatMetadata(memories: [UUID()], files: ["README.md"])
        let event = ChatEvent.meta(event: .generationContext(metadata: metadata))
        if case .meta(event: .generationContext(let meta)) = event {
            #expect(meta.files.count == 1)
        } else {
            Issue.record("Expected meta.generationContext")
        }
    }

    @Test

    func testChatEventGenerationCompleted() {
        let message = Message(content: "Done", role: .assistant)
        let metadata = APIResponseMetadata(model: "test-model", duration: 1.5, tokensPerSecond: 50.0)
        let event = ChatEvent.completion(event: .generationCompleted(message: message, metadata: metadata))
        if case .completion(event: .generationCompleted(let msg, _)) = event {
            #expect(msg.content == "Done")
        } else {
            Issue.record("Expected completion.generationCompleted")
        }
    }

    @Test

    func testChatEventError() {
        let event = ChatEvent.error(event: .error(message: "Test error"))
        if case .error(event: .error(let msg)) = event {
            #expect(msg == "Test error")
        } else {
            Issue.record("Expected error.error")
        }
    }
}
