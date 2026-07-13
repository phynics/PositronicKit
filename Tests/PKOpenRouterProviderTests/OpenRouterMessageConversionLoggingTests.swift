import Foundation
import Logging
@testable import PKOpenRouterProvider
import PKShared
import PKUtilities
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

struct OpenRouterMessageConversionLoggingTests {
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
