import Foundation
import Logging
import PKShared
import PKUtilities
import PKTestSupport
import Testing
@testable import PositronicKit

@Suite("Logging redaction")
struct LoggingRedactionTests {
    @Test("ChatRunRequest description does not include the user message")
    func requestDescriptionDoesNotLeakMessage() {
        let secret = "user-secret-prompt-7f3c"
        let request = ChatRunRequest(timelineId: UUID(), message: secret)

        #expect(!request.description.contains(secret))
        #expect(request.description.contains("message: <redacted>"))
    }

    @Test("default logging configuration disables payloads and sanitizes structured text")
    func defaultLoggingPolicy() {
        let configuration = LoggingConfiguration.default

        #expect(!configuration.redactionPolicy.logsPayloads)
        #expect(configuration.redactionPolicy.sanitize("failed \u{1B}[31m🛠️\u{1B}[0m") == "failed [redacted]")
        #expect(configuration.redactionPolicy.payload("secret") == "[redacted]")
    }

    @Test("logged errors expose stable identity and correlation metadata")
    func errorMetadata() {
        let metadata = LoggingMetadata.forError(
            ToolError.executionFailed("secret response"),
            correlationID: "corr-123"
        )

        #expect(metadata[LogKeys.errorDomain]?.description == PKErrorDomain.tool)
        #expect(metadata[LogKeys.errorCode]?.description == "203")
        #expect(metadata[LogKeys.correlationID]?.description == "corr-123")
    }

    // MARK: - PKRR-024: structured handlers receive printable plain text

    @Test("ToolRouter log records stay plain text (no ANSI escapes or emoji)")
    func toolRouterLogRecordsArePlainText() async throws {
        let sink = CapturingLogSink()
        let configuration = LoggingConfiguration(loggerFactory: { _ in
            Logger(label: "test.tool-router") { _ in CapturingLogHandler(sink: sink) }
        })

        // Build a minimal ToolRouter directly so we can inject the capturing logger config
        // without going through the PositronicKit facade. The timeline is never created in the
        // store, so `execute` logs "Routing ..." then throws `toolNotFound` — the log record is
        // captured before the throw, which is all this regression test inspects.
        let persistence = MockPersistenceService()
        let workspaceRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pkrr-024-\(UUID().uuidString)")
        let timelineManager = TimelineManager(
            stores: .init(
                timelineStore: persistence,
                messageStore: persistence,
                workspaceStore: persistence,
                toolPersistence: persistence,
                memoryStore: persistence
            ),
            workspaceRoot: workspaceRoot
        )
        let router = ToolRouter(
            timelineManager: timelineManager,
            messageStore: persistence,
            loggingConfiguration: configuration
        )

        let timelineId = UUID()
        _ = try? await router.execute(
            tool: .known(id: "calculator"),
            arguments: [:],
            timelineId: timelineId
        )

        let entries = sink.all()
        let routing = try #require(entries.first { $0.message.contains("Routing") })

        // Structured handlers receive printable plain text: no ESC bytes and ASCII-only.
        #expect(!routing.message.contains("\u{1B}"))
        #expect(routing.message.allSatisfy { $0.isASCII })

        // Identity travels in structured metadata, not embedded in the colored message string.
        #expect(routing.metadata[LogKeys.toolName]?.description == "calculator")
        #expect(routing.metadata[LogKeys.timelineID]?.description == timelineId.uuidString)
    }

    // MARK: - Capture harness

    private final class CapturingLogSink: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [(level: Logger.Level, message: String, metadata: Logger.Metadata)] = []

        func append(level: Logger.Level, message: String, metadata: Logger.Metadata) {
            lock.lock()
            defer { lock.unlock() }
            entries.append((level, message, metadata))
        }

        func all() -> [(level: Logger.Level, message: String, metadata: Logger.Metadata)] {
            lock.lock()
            defer { lock.unlock() }
            return entries
        }
    }

    private struct CapturingLogHandler: LogHandler {
        let sink: CapturingLogSink
        var logLevel: Logger.Level = .trace
        var metadata = Logger.Metadata()

        subscript(metadataKey key: String) -> Logger.Metadata.Value? {
            get { metadata[key] }
            set { metadata[key] = newValue }
        }

        func log(
            level: Logger.Level,
            message: Logger.Message,
            metadata: Logger.Metadata?,
            source _: String,
            file _: String,
            function _: String,
            line _: UInt
        ) {
            sink.append(level: level, message: message.description, metadata: metadata ?? [:])
        }
    }
}
