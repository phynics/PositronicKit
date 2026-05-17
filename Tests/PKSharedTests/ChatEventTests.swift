import Testing
@testable import PKShared
import Foundation

@Suite final class ChatEventTests {
    @Test

    func testGenerationCancelledEvent() throws {
        // This should fail to compile after the rename or if I use the new name now
        // But for TDD, I should write something that expects 'generationCancelled'
        let event = ChatEvent.generationCancelled()

        let encoder = JSONEncoder()
        let data = try encoder.encode(event)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(ChatEvent.self, from: data)

        if case let .error(errorEvent) = decoded {
            if case .generationCancelled = errorEvent {
                // Success
            } else {
                Issue.record("Expected .generationCancelled, got \(errorEvent)")
            }
        } else {
            Issue.record("Expected .error, got \(decoded)")
        }
    }

    @Test
    func usageGuideEventPatternMatchesCurrentShape() {
        let completionMeta = APIResponseMetadata(totalTokens: 42)
        let toolDeltaEvent = ChatEvent.delta(event: .toolCall(delta: ToolCallDelta(
            index: 0,
            id: "call_1",
            name: "lookup_weather",
            arguments: "{}"
        )))
        let toolErrorEvent = ChatEvent.error(event: .toolCallError(
            toolCallId: "call_1",
            name: "lookup_weather",
            error: "bad args"
        ))
        let metaCompletionEvent = ChatEvent.meta(event: .generationCompleted(
            message: Message(content: "done", role: .assistant),
            metadata: completionMeta
        ))
        let completionEvent = ChatEvent.completion(event: .streamCompleted)

        switch toolDeltaEvent {
        case .delta(let event):
            switch event {
            case .toolCall(let delta):
                #expect(delta.id == "call_1")
                #expect(delta.name == "lookup_weather")
            default:
                Issue.record("Expected nested delta.toolCall event")
            }
        default:
            Issue.record("Expected outer delta event")
        }

        switch toolErrorEvent {
        case .error(let event):
            switch event {
            case .toolCallError(let toolCallId, let name, let error):
                #expect(toolCallId == "call_1")
                #expect(name == "lookup_weather")
                #expect(error == "bad args")
            default:
                Issue.record("Expected nested error.toolCallError event")
            }
        default:
            Issue.record("Expected outer error event")
        }

        switch metaCompletionEvent {
        case .meta(let event):
            switch event {
            case .generationCompleted(let message, let metadata):
                #expect(message.content == "done")
                #expect(metadata.totalTokens == 42)
            default:
                Issue.record("Expected nested meta.generationCompleted event")
            }
        default:
            Issue.record("Expected outer meta event")
        }

        switch completionEvent {
        case .completion(let event):
            switch event {
            case .streamCompleted:
                break
            default:
                Issue.record("Expected nested completion.streamCompleted event")
            }
        default:
            Issue.record("Expected outer completion event")
        }
    }
}
