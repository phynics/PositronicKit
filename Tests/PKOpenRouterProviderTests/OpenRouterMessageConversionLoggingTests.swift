import Foundation
import Logging
@testable import PKOpenRouterProvider
import PKContracts
import PKUtilities
import Synchronization
import Testing

private final class CapturingLogSink: Sendable {
    private struct State: Sendable {
        var messages: [String] = []
    }

    private let state = Mutex(State())

    func append(_ message: String) {
        state.withLock { $0.messages.append(message) }
    }

    func all() -> [String] {
        state.withLock { $0.messages }
    }
}

private struct CapturingLogHandler: LogHandler {
    let sink: CapturingLogSink
    var logLevel: Logger.Level = .debug
    var metadata = Logger.Metadata()

    subscript(metadataKey key: String) -> Logger.MetadataValue? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(
        level _: Logger.Level,
        message: Logger.Message,
        metadata _: Logger.Metadata?,
        source _: String,
        file _: String,
        function _: String,
        line _: UInt
    ) {
        sink.append(message.description)
    }
}

struct OpenRouterMessageConversionLoggingTests {
    @Test("Ordered media encodes as OpenRouter content parts")
    func orderedMediaEncodesAsContentParts() throws {
        let message = LLMMessage(role: .user, content: MessageContent(parts: [
            .text("before"),
            .image(ImageContent(data: Data([0x01]), mediaType: "image/png", detail: .low)),
            .audio(AudioContent(data: Data([0x02]), format: .wav)),
            .text("after"),
        ]))

        let encoded = try JSONEncoder().encode(OpenRouterMessage(message))
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let content = try #require(object["content"] as? [[String: Any]])

        #expect(content.compactMap { $0["type"] as? String } == ["text", "image_url", "input_audio", "text"])
        #expect((content[1]["image_url"] as? [String: Any])?["url"] as? String == "data:image/png;base64,AQ==")
        #expect((content[2]["input_audio"] as? [String: Any])?["data"] as? String == "Ag==")
    }

    @Test("Assistant audio continuation encodes by provider id without bytes")
    func assistantAudioContinuationEncodesByID() throws {
        let message = LLMMessage(role: .assistant, content: MessageContent(parts: [
            .text("hello"),
            .audio(AudioContent(
                data: Data([0x01, 0x02]),
                format: .wav,
                transcript: "hello",
                continuation: AudioContinuationReference(
                    provider: .openRouter,
                    id: "audio_123",
                    expiresAt: Date().addingTimeInterval(60)
                )
            )),
        ]))

        let encoded = try JSONEncoder().encode(OpenRouterMessage(message))
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["content"] as? String == "hello")
        #expect((object["audio"] as? [String: Any])?["id"] as? String == "audio_123")
        #expect(String(decoding: encoded, as: UTF8.self).contains("AQI=") == false)
    }

    @Test("Tool-role message with nil toolCallID logs a warning")
    func toolMessageWithNilToolCallIDLogsWarning() {
        let sink = CapturingLogSink()
        let logger = Logger(label: "test.openrouter.message-conversion") { _ in
            CapturingLogHandler(sink: sink)
        }

        let message = LLMMessage(role: .tool, content: "result", toolCallID: nil)
        let converted = OpenRouterMessage(message, logger: logger)

        #expect(converted.toolCallID == nil)

        let messages = sink.all()
        #expect(messages.contains(where: { $0.contains("missing toolCallID") }))
    }

    @Test("Tool-role message with a toolCallID does not log a warning")
    func toolMessageWithToolCallIDDoesNotLogWarning() {
        let sink = CapturingLogSink()
        let logger = Logger(label: "test.openrouter.message-conversion") { _ in
            CapturingLogHandler(sink: sink)
        }

        let message = LLMMessage(role: .tool, content: "result", toolCallID: "call_1")
        let converted = OpenRouterMessage(message, logger: logger)

        #expect(converted.toolCallID == "call_1")
        #expect(sink.all().isEmpty)
    }
}
