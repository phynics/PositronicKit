import PKShared
import Foundation

/// ANSI color codes for terminal output.
///
/// Color is opt-in and handler-owned. `ANSIColors` is kept public (PKV3-007) for downstream
/// terminal consumers, but escape sequences must never be embedded in `Logger` message
/// strings: structured sinks (JSON, OSLog, files, telemetry) would receive the raw escape
/// bytes and any presentation emoji, complicating searching and parsing (PKRR-024).
///
/// - For terminal rendering where the caller owns the TTY decision, use
///   ``colorize(_:color:enabled:)`` and pass the handler's own TTY verdict as `enabled`.
/// - For log message construction, never colorize; carry identity in `Logger.Metadata`
///   (see `LogKeys`) and route any caller-supplied display text through
///   ``LogRedactionPolicy/sanitizeStructured(_:)``.
/// - To neutralize a string that may already contain escape sequences (e.g. third-party
///   output), use ``strip(_:)``. ``LogRedactionPolicy/sanitize(_:)`` delegates ANSI removal
///   here so the escape-sequence grammar has one source of truth.
public enum ANSIColors {
    public static let reset = "\u{001B}[0m"
    public static let bold = "\u{001B}[1m"
    public static let dim = "\u{001B}[2m"
    public static let italic = "\u{001B}[3m"
    public static let underline = "\u{001B}[4m"

    public static let black = "\u{001B}[30m"
    public static let red = "\u{001B}[31m"
    public static let green = "\u{001B}[32m"
    public static let yellow = "\u{001B}[33m"
    public static let blue = "\u{001B}[34m"
    public static let magenta = "\u{001B}[35m"
    public static let cyan = "\u{001B}[36m"
    public static let white = "\u{001B}[37m"

    public static let brightBlack = "\u{001B}[90m"
    public static let brightRed = "\u{001B}[91m"
    public static let brightGreen = "\u{001B}[92m"
    public static let brightYellow = "\u{001B}[93m"
    public static let brightBlue = "\u{001B}[94m"
    public static let brightMagenta = "\u{001B}[95m"
    public static let brightCyan = "\u{001B}[96m"
    public static let brightWhite = "\u{001B}[97m"

    /// Wraps `text` with `color` escape sequences.
    ///
    /// - Important: This overload always emits escape sequences with no TTY detection, which
    ///   makes it unsafe for log message construction or any non-terminal sink. It is retained
    ///   for source/binary compatibility with downstream terminal consumers (PKV3-007). New
    ///   code should call ``colorize(_:color:enabled:)`` and pass the owning handler's TTY
    ///   decision explicitly.
    public static func colorize(_ text: String, color: String) -> String {
        "\(color)\(text)\(reset)"
    }

    /// Handler-owned colorization: wraps `text` with `color` escape sequences iff `enabled` is
    /// `true`, otherwise returns `text` unchanged.
    ///
    /// Pass the owning handler's TTY verdict directly (e.g. `isatty(fileno(stdout)) != 0`,
    /// or a host-level `colorEnabled` flag). Use this in any context where the output target
    /// is not guaranteed to be a terminal — log records, JSON, files, and telemetry must
    /// receive the `enabled: false` (plain-text) path.
    public static func colorize(_ text: String, color: String, enabled: Bool) -> String {
        enabled ? "\(color)\(text)\(reset)" : text
    }

    /// Removes CSI ANSI escape sequences (the grammar emitted by this type) from `value`,
    /// returning the plain-text payload.
    ///
    /// This is the single source of truth for the escape-sequence grammar used by
    /// ``LogRedactionPolicy/sanitize(_:)``. It strips only CSI sequences (e.g. `ESC[31m`,
    /// `ESC[0m`); non-ASCII presentation characters such as emoji are left intact for the
    /// caller to redact or keep as policy dictates.
    public static func strip(_ value: String) -> String {
        let pattern = "\u{001B}\\[[0-?]*[ -/]*[@-~]"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return value
        }
        return regex.stringByReplacingMatches(
            in: value,
            range: NSRange(value.startIndex..., in: value),
            withTemplate: ""
        )
    }
}
