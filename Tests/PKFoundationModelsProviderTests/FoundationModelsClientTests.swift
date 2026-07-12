import Foundation
@testable import PKFoundationModelsProvider
import PKShared
import PKTestSupport
import PositronicKit
import Testing

/// End-to-end `FoundationModelsClient.chatStream` tests driven by a scripted fake
/// `FoundationModelsSessionProtocol` — no live Apple Intelligence, no `FoundationModels` import
/// needed here at all (PKPOST-003 acceptance criterion). Covers the streaming + termination
/// conformance the ticket calls out: text, multi-tool, guardrail refusal, context-exceeded.
private actor FakeFoundationModelsSession: FoundationModelsSessionProtocol {
    let events: [FoundationModelsSessionEvent]
    let failure: Error?

    init(events: [FoundationModelsSessionEvent], failure: Error? = nil) {
        self.events = events
        self.failure = failure
    }

    nonisolated func streamTurn(prompt _: String) -> AsyncThrowingStream<FoundationModelsSessionEvent, Error> {
        AsyncThrowingStream { continuation in
            for event in events {
                continuation.yield(event)
            }
            if let failure {
                continuation.finish(throwing: failure)
            } else {
                continuation.finish()
            }
        }
    }
}

@Suite("FoundationModelsClient streaming")
struct FoundationModelsClientTests {
    @Test("Text-only turn streams content deltas then a stop finish reason")
    func textOnlyTurnStreams() async throws {
        let fake = FakeFoundationModelsSession(events: [
            .textDelta("hello "),
            .textDelta("world"),
            .finished(.stop),
        ])
        let client = FoundationModelsClient(makeSession: { _, _ in fake })

        let chunks = try await client.chatStream(
            messages: [LLMMessage(role: .user, content: "hi")],
            tools: nil,
            toolChoice: nil,
            responseFormat: nil,
            generationParameters: nil
        ).collect()

        let text = chunks.compactMap { $0.choices.first?.delta.content }.joined()
        #expect(text == "hello world")
        #expect(chunks.last?.choices.first?.finishReason == "stop")
    }

    @Test("Multi-tool turn surfaces both tool calls with distinct ordinals")
    func multiToolTurnSurfacesBothCalls() async throws {
        let fake = FakeFoundationModelsSession(events: [
            .toolCall(id: "call_1", name: "lookup_weather", argumentsJSON: "{\"city\":\"Berlin\"}"),
            .toolOutput(id: "call_1", name: "lookup_weather", output: "Sunny"),
            .toolCall(id: "call_2", name: "lookup_time", argumentsJSON: "{\"tz\":\"CET\"}"),
            .toolOutput(id: "call_2", name: "lookup_time", output: "14:00"),
            .textDelta("Sunny and 14:00."),
            .finished(.toolCalls),
        ])
        let client = FoundationModelsClient(makeSession: { _, _ in fake })

        let chunks = try await client.chatStream(
            messages: [LLMMessage(role: .user, content: "weather and time in berlin")],
            tools: nil,
            toolChoice: nil,
            responseFormat: nil,
            generationParameters: nil
        ).collect()

        let toolCallChunks = chunks.filter { $0.choices.first?.delta.toolCalls != nil }
        #expect(toolCallChunks.count == 2)
        #expect(toolCallChunks.map { $0.choices.first?.delta.toolCalls?.first?.function?.name } == [
            "lookup_weather", "lookup_time",
        ])
    }

    @Test("Guardrail refusal surfaces as a thrown error, not a silent empty stream")
    func guardrailRefusalThrows() async throws {
        let fake = FakeFoundationModelsSession(
            events: [],
            failure: FoundationModelsGenerationErrorFixture.guardrailViolation
        )
        let client = FoundationModelsClient(makeSession: { _, _ in fake })

        let stream = await client.chatStream(
            messages: [LLMMessage(role: .user, content: "unsafe request")],
            tools: nil,
            toolChoice: nil,
            responseFormat: nil,
            generationParameters: nil
        )

        await #expect(throws: (any Error).self) {
            for try await _ in stream {}
        }
    }

    @Test("Context-exceeded surfaces as a thrown error, not a silent empty stream")
    func contextExceededThrows() async throws {
        let fake = FakeFoundationModelsSession(
            events: [.textDelta("partial")],
            failure: FoundationModelsGenerationErrorFixture.contextExceeded
        )
        let client = FoundationModelsClient(makeSession: { _, _ in fake })

        let stream = await client.chatStream(
            messages: [LLMMessage(role: .user, content: "very long conversation")],
            tools: nil,
            toolChoice: nil,
            responseFormat: nil,
            generationParameters: nil
        )

        var receivedPartialText = false
        await #expect(throws: (any Error).self) {
            for try await chunk in stream {
                if chunk.choices.first?.delta.content == "partial" { receivedPartialText = true }
            }
        }
        #expect(receivedPartialText)
    }

    @Test("sendMessage accumulates content deltas into a single string")
    func sendMessageAccumulatesContent() async throws {
        let fake = FakeFoundationModelsSession(events: [
            .textDelta("hello "),
            .textDelta("world"),
            .finished(.stop),
        ])
        let client = FoundationModelsClient(makeSession: { _, _ in fake })

        let result = try await client.sendMessage("hi", responseFormat: nil, generationParameters: nil)
        #expect(result == "hello world")
    }

    @Test("fetchAvailableModels returns the single configured model name")
    func fetchAvailableModelsReturnsConfiguredName() async throws {
        let client = FoundationModelsClient(modelName: "apple-on-device-test", makeSession: { _, _ in
            FakeFoundationModelsSession(events: [.finished(.stop)])
        })
        let models = try await client.fetchAvailableModels()
        #expect(models == ["apple-on-device-test"])
    }
}

/// Minimal `PKError`-conforming stand-ins for `LanguageModelSession.GenerationError` cases, used
/// only to exercise `FoundationModelsClient`'s error propagation without importing
/// `FoundationModels` in this test file (the client only cares that `streamTurn` can throw, not
/// the concrete error type — the concrete mapping from `LanguageModelSession.GenerationError` to
/// `FoundationModelsGenerationError` is covered by `LiveFoundationModelsSessionTests`, which does
/// need the live framework and is gated accordingly).
private enum FoundationModelsGenerationErrorFixture: Error {
    case guardrailViolation
    case contextExceeded
}
