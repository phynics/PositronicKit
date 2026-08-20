import Foundation
import Logging
@testable import PKContracts
import PKUtilities
import Synchronization
import Testing

/// Regression coverage for PKRR-024: ANSI escape sequences and presentation emoji must never
/// land in structured log records. `ANSIColors` is kept public (PKV3-007) for downstream
/// terminal consumers, so these tests pin both the legacy footgun (colorize always emits codes
/// with no TTY detection) and the new handler-owned plain-text path that hosts should use when
/// the output target is a `Logger`, JSON, OSLog, file, or telemetry sink.
@Suite("ANSIColors logging hygiene")
struct ANSIColorsLoggingTests {

    // MARK: - Capture harness

    private final class CapturingLogSink: Sendable {
        private struct State: Sendable {
            var entries: [(level: Logger.Level, message: String, metadata: Logger.Metadata)] = []
        }

        private let state = Mutex(State())

        func append(level: Logger.Level, message: String, metadata: Logger.Metadata) {
            state.withLock { $0.entries.append((level, message, metadata)) }
        }

        func all() -> [(level: Logger.Level, message: String, metadata: Logger.Metadata)] {
            state.withLock { $0.entries }
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

    private func capturingLogger(_ sink: CapturingLogSink) -> Logger {
        Logger(label: "test.ansi-colors") { _ in CapturingLogHandler(sink: sink) }
    }

    private func containsEscape(_ string: String) -> Bool {
        string.unicodeScalars.contains { $0 == "\u{001B}" }
    }

    // MARK: - Legacy footgun characterization (reproduces the "current ANSI in records" problem)

    @Test("legacy colorize always emits escape sequences with no TTY detection")
    func legacyColorizeAlwaysEmitsEscapeSequences() {
        let colored = ANSIColors.colorize("calculator", color: ANSIColors.brightCyan)

        // The public legacy overload exists for downstream terminal consumers; it unconditionally
        // wraps the text in escape sequences. This is the footgun PKRR-024 guards against: any
        // caller that routes this string into a Logger/JSON/file sink pollutes the record.
        #expect(containsEscape(colored))
        #expect(colored.hasPrefix(ANSIColors.brightCyan))
        #expect(colored.hasSuffix(ANSIColors.reset))
    }

    @Test("logging legacy colorize output verbatim lands escape bytes and emoji in the record")
    func legacyColorizeOutputLoggedVerbatimArrivesInRecords() {
        let sink = CapturingLogSink()
        let logger = capturingLogger(sink)

        // Simulates the pre-PKRR-013 log construction that PKRR-024 regression-tests against:
        // a colored tool name (with a presentation glyph) embedded directly in the message.
        let coloredTool = ANSIColors.colorize("🛠️ calc", color: ANSIColors.brightCyan)
        logger.info("Routing \(coloredTool) in thread abc12345")

        let entries = sink.all()
        #expect(entries.count == 1)
        let message = entries[0].message

        // The escape sequences and the emoji survive into the captured record verbatim —
        // this is exactly the structured-sink pollution the ticket describes.
        #expect(containsEscape(message))
        #expect(message.contains("🛠️"))
    }

    // MARK: - Handler-owned plain-text path

    @Test("colorize with enabled=false produces plain text for structured sinks")
    func colorizeEnabledFalseProducesPlainText() {
        let plain = ANSIColors.colorize("calculator", color: ANSIColors.brightCyan, enabled: false)
        #expect(plain == "calculator")
        #expect(!containsEscape(plain))
    }

    @Test("colorize with enabled=true still emits escape sequences (opt-in terminal color)")
    func colorizeEnabledTrueEmitsEscapeSequences() {
        let colored = ANSIColors.colorize("calculator", color: ANSIColors.brightCyan, enabled: true)
        #expect(containsEscape(colored))
        #expect(colored == ANSIColors.colorize("calculator", color: ANSIColors.brightCyan))
    }

    @Test("enabled colorize preserves emoji payload when color is on")
    func colorizeEnabledTruePreservesEmoji() {
        let colored = ANSIColors.colorize("🛠️ calc", color: ANSIColors.green, enabled: true)
        #expect(colored.contains("🛠️"))
        #expect(containsEscape(colored))
    }

    // MARK: - Strip helper (plain-text sanitizer for already-colored input)

    @Test("strip removes ANSI escape sequences from a colored string")
    func stripRemovesANSIEscapeSequences() {
        let colored = ANSIColors.colorize("calculator", color: ANSIColors.brightCyan, enabled: true)
        let stripped = ANSIColors.strip(colored)
        #expect(stripped == "calculator")
        #expect(!containsEscape(stripped))
    }

    @Test("strip is a no-op on already-plain text")
    func stripIsNoOpOnPlainText() {
        #expect(ANSIColors.strip("plain text 123") == "plain text 123")
    }

    @Test("strip removes stacked color sequences leaving inner text intact")
    func stripRemovesStackedSequences() {
        let stacked = "\(ANSIColors.brightCyan)\(ANSIColors.bold)tool\(ANSIColors.reset)\(ANSIColors.reset)"
        #expect(ANSIColors.strip(stacked) == "tool")
    }

    // MARK: - Coordination with PKRR-013 LogRedactionPolicy

    @Test("LogRedactionPolicy.sanitize strips ANSI escapes and redacts presentation emoji")
    func sanitizeStripsANSIAndRedactsEmoji() {
        let policy = LogRedactionPolicy.default
        let colored = ANSIColors.colorize("🛠️", color: ANSIColors.red, enabled: true)
        let sanitized = policy.sanitize("failed \(colored)")

        #expect(!containsEscape(sanitized))
        #expect(!sanitized.contains("🛠️"))
        #expect(sanitized == "failed [redacted]")
    }
}
