import Foundation

/// ANSI escape-sequence handling for log hygiene.
///
/// Escape sequences must never be embedded in `Logger` message strings: structured sinks (JSON,
/// OSLog, files, telemetry) would receive the raw escape bytes, complicating searching and
/// parsing (PKRR-024). ``strip(_:)`` neutralizes text that may already contain escape sequences
/// (e.g. third-party output); ``LogRedactionPolicy/sanitize(_:)`` delegates ANSI removal here so
/// the escape-sequence grammar has one source of truth.
package enum ANSIColors {
    /// Removes CSI ANSI escape sequences from `value`, returning the plain-text payload.
    ///
    /// It strips only CSI sequences (e.g. `ESC[31m`, `ESC[0m`); non-ASCII presentation
    /// characters such as emoji are left intact for the caller to redact or keep as policy
    /// dictates.
    package static func strip(_ value: String) -> String {
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
