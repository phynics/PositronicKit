import Foundation
import Logging

/// A colorful log handler for Monad Server
public struct MonadLogHandler: LogHandler {
    private let labelPrefix: String
    public var logLevel: Logger.Level = .info
    public var metadata = Logger.Metadata()

    public init(label: String) {
        // Extract the last component of the label for cleaner display
        let module = label.components(separatedBy: ".").last ?? label
        labelPrefix = ANSIColors.colorize("[\(module)]", color: ANSIColors.brightBlue)
    }

    /// Configuration for a single log entry
    private struct LogEntry {
        let level: Logger.Level
        let message: Logger.Message
        let metadata: Logger.Metadata?
    }

    // swiftlint:disable:next function_parameter_count
    public func log(level: Logger.Level,
                    message: Logger.Message,
                    metadata: Logger.Metadata?,
                    source _: String,
                    file _: String,
                    function _: String,
                    line _: UInt) {
        let entry = LogEntry(level: level, message: message, metadata: metadata)
        formatAndPrint(entry)
    }

    private func formatAndPrint(_ entry: LogEntry) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let levelColor = color(for: entry.level)
        let levelStr = ANSIColors.colorize(entry.level.rawValue.uppercased(), color: levelColor)

        var messageStr = "\(timestamp) \(levelStr) \(labelPrefix) \(entry.message)"

        // Add metadata if present
        let mergedMetadata = metadata.merging(entry.metadata ?? [:], uniquingKeysWith: { _, new in new })
        if !mergedMetadata.isEmpty {
            let metadataStr = mergedMetadata.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
            messageStr += " " + ANSIColors.colorize("{\(metadataStr)}", color: ANSIColors.dim)
        }

        print(messageStr)
    }

    private func color(for level: Logger.Level) -> String {
        switch level {
        case .trace, .debug: return ANSIColors.dim
        case .info: return ANSIColors.green
        case .notice: return ANSIColors.brightCyan
        case .warning: return ANSIColors.yellow
        case .error: return ANSIColors.red
        case .critical: return ANSIColors.colorize(ANSIColors.red, color: ANSIColors.bold)
        }
    }

    public subscript(metadataKey key: String) -> Logger.MetadataValue? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }
}
