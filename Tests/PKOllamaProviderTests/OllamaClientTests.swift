import Foundation
import struct JSONSchema.Schema
import Logging
@testable import PKOllamaProvider
import PKShared
import Testing

private final class CapturingLogSink: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String] = []

    func append(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        messages.append(message)
    }

    func all() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return messages
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

struct OllamaClientTests {
    @Test func ollamaEndpointNormalization() {
        let e1 = OllamaEndpoint(rawValue: "http://localhost:11434/")
        #expect(e1.url.absoluteString == "http://localhost:11434")
        #expect(e1.chatURL.absoluteString == "http://localhost:11434/api/chat")

        let e2 = OllamaEndpoint(rawValue: "http://localhost:11434/api")
        #expect(e2.url.absoluteString == "http://localhost:11434")

        let e3 = OllamaEndpoint(rawValue: "  http://localhost:11434/api/  ")
        #expect(e3.url.absoluteString == "http://localhost:11434")
    }

    @Test func ollamaMessageInitialization() {
        let systemParam = LLMMessage(role: .system, content: "system prompt")
        let message = OllamaMessage(from: systemParam)
        #expect(message.role == "system")
        #expect(message.content == "system prompt")

        let userParam = LLMMessage(role: .user, content: "hello")
        let userMsg = OllamaMessage(from: userParam)
        #expect(userMsg.role == "user")
        #expect(userMsg.content == "hello")
    }

    @Test func ollamaToolInitialization() {
        let toolParam = LLMToolDefinition(
            name: "test_tool",
            description: "test description",
            parameters: makeEmptyObjectSchema()
        )
        let tool = OllamaTool(from: toolParam)
        #expect(tool.type == "function")
        #expect(tool.function.name == "test_tool")
        #expect(tool.function.description == "test description")
    }

    @Test func ollamaChatRequestEncodesJSONSchemaFormatAsObject() throws {
        let schema = try Schema(instance: #"{"type":"object","properties":{"tags":{"type":"array","items":{"type":"string"}}},"required":["tags"]}"#)
        let request = OllamaChatRequest(
            model: "llama3.1",
            messages: [OllamaMessage(from: LLMMessage(role: .user, content: "Extract tags"))],
            stream: true,
            format: .jsonSchema(schema),
            tools: nil,
            options: nil
        )

        let data = try JSONEncoder().encode(request)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let format = try #require(object["format"] as? [String: Any])

        #expect(format["type"] as? String == "object")
        #expect(format["required"] as? [String] == ["tags"])
    }

    @Test func ollamaChatRequestEncodesJSONModeFormatAsString() throws {
        let request = OllamaChatRequest(
            model: "llama3.1",
            messages: [OllamaMessage(from: LLMMessage(role: .user, content: "Extract tags"))],
            stream: true,
            format: .jsonObject,
            tools: nil,
            options: nil
        )

        let data = try JSONEncoder().encode(request)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["format"] as? String == "json")
    }

    @Test func ollamaMessageLogsWarningWhenToolCallArgumentsAreNotAnObject() throws {
        let sink = CapturingLogSink()
        let logger = Logger(label: "test.ollama.message-conversion") { _ in
            CapturingLogHandler(sink: sink)
        }

        let toolCall = LLMToolCall(id: "call_1", name: "lookup_weather", arguments: "[\"Berlin\"]")
        let param = LLMMessage(role: .assistant, content: "", toolCalls: [toolCall])

        let message = OllamaMessage(from: param, logger: logger)

        let toolCalls = try #require(message.toolCalls)
        #expect(toolCalls.count == 1)
        #expect(toolCalls.first?.function.name == "lookup_weather")
        #expect(toolCalls.first?.function.arguments["_rawArguments"] != nil)

        let messages = sink.all()
        #expect(messages.contains(where: { $0.contains("did not decode as a JSON object") }))
    }

    @Test func ollamaMessageLogsWarningWhenToolCallArgumentsAreNotValidJSON() throws {
        let sink = CapturingLogSink()
        let logger = Logger(label: "test.ollama.message-conversion") { _ in
            CapturingLogHandler(sink: sink)
        }

        let toolCall = LLMToolCall(id: "call_1", name: "lookup_weather", arguments: "not json at all {")
        let param = LLMMessage(role: .assistant, content: "", toolCalls: [toolCall])

        let message = OllamaMessage(from: param, logger: logger)

        let toolCalls = try #require(message.toolCalls)
        #expect(toolCalls.count == 1)
        #expect(toolCalls.first?.function.arguments.isEmpty == true)

        let messages = sink.all()
        #expect(messages.contains(where: { $0.contains("failed to decode as JSON at all") }))
    }
}
