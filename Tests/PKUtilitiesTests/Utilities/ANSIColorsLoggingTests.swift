@testable import PKContracts
import Testing

/// Regression coverage for PKRR-024: ANSI escape sequences and presentation emoji must never
/// land in structured log records.
@Suite("ANSIColors logging hygiene")
struct ANSIColorsLoggingTests {
    private let brightCyan = "\u{001B}[96m"
    private let bold = "\u{001B}[1m"
    private let reset = "\u{001B}[0m"

    private func containsEscape(_ string: String) -> Bool {
        string.unicodeScalars.contains { $0 == "\u{001B}" }
    }

    @Test("strip removes ANSI escape sequences from a colored string")
    func stripRemovesANSIEscapeSequences() {
        let stripped = ANSIColors.strip("\(brightCyan)calculator\(reset)")
        #expect(stripped == "calculator")
        #expect(!containsEscape(stripped))
    }

    @Test("strip is a no-op on already-plain text")
    func stripIsNoOpOnPlainText() {
        #expect(ANSIColors.strip("plain text 123") == "plain text 123")
    }

    @Test("strip removes stacked color sequences leaving inner text intact")
    func stripRemovesStackedSequences() {
        #expect(ANSIColors.strip("\(brightCyan)\(bold)tool\(reset)\(reset)") == "tool")
    }

    @Test("LogRedactionPolicy.sanitize strips ANSI escapes and redacts presentation emoji")
    func sanitizeStripsANSIAndRedactsEmoji() {
        let sanitized = LogRedactionPolicy.default.sanitize("failed \u{001B}[31m🛠️\(reset)")

        #expect(!containsEscape(sanitized))
        #expect(!sanitized.contains("🛠️"))
        #expect(sanitized == "failed [redacted]")
    }
}
