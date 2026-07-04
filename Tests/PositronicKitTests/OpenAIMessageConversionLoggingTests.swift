import Foundation
import Logging
import OpenAI
@testable import PKOpenAIProvider
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

struct OpenAIMessageConversionLoggingTests {
    @Test("Tool-role message with nil toolCallID logs a warning and still sends an empty tool_call_id")
    func toolMessageWithNilToolCallIDLogsWarning() {
        let sink = CapturingLogSink()
        let logger = Logger(label: "test.openai.message-conversion") { _ in
            CapturingLogHandler(sink: sink)
        }

        let message = LLMMessage(role: .tool, content: "result", toolCallID: nil)
        let param = message.toOpenAIMessageParam(logger: logger)

        guard case let .tool(toolMessage) = param else {
            Issue.record("Expected a .tool message param")
            return
        }
        #expect(toolMessage.toolCallId == "")

        let messages = sink.all()
        #expect(messages.contains(where: { $0.contains("missing toolCallID") }))
    }

    @Test("Tool-role message with a toolCallID does not log a warning")
    func toolMessageWithToolCallIDDoesNotLogWarning() {
        let sink = CapturingLogSink()
        let logger = Logger(label: "test.openai.message-conversion") { _ in
            CapturingLogHandler(sink: sink)
        }

        let message = LLMMessage(role: .tool, content: "result", toolCallID: "call_1")
        let param = message.toOpenAIMessageParam(logger: logger)

        guard case let .tool(toolMessage) = param else {
            Issue.record("Expected a .tool message param")
            return
        }
        #expect(toolMessage.toolCallId == "call_1")
        #expect(sink.all().isEmpty)
    }
}
