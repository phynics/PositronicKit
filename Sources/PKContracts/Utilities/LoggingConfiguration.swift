import Foundation
import Logging

/// Controls logger construction and the amount of user-controlled data allowed in logs.
/// Payloads are disabled by default; hosts must explicitly opt in for diagnostics.
public struct LoggingConfiguration: Sendable {
    public let loggerFactory: @Sendable (String) -> Logger
    public let redactionPolicy: LogRedactionPolicy

    public init(
        redactionPolicy: LogRedactionPolicy = .default,
        loggerFactory: @escaping @Sendable (String) -> Logger = { .init(label: "com.positronickit.\($0)") }
    ) {
        self.loggerFactory = loggerFactory
        self.redactionPolicy = redactionPolicy
    }

    public static let `default` = LoggingConfiguration()

    public func logger(named name: String) -> Logger {
        loggerFactory(name)
    }
}

/// Redaction rules for structured PositronicKit logs.
public struct LogRedactionPolicy: Sendable, Equatable {
    public let logsPayloads: Bool

    public init(logsPayloads: Bool = false) {
        self.logsPayloads = logsPayloads
    }

    public static let `default` = LogRedactionPolicy()

    /// Removes terminal control sequences and non-ASCII presentation characters from log text.
    public func sanitize(_ value: String) -> String {
        let withoutANSI = ANSIColors.strip(value)
        var result = ""
        var replacingPresentation = false
        for scalar in withoutANSI.unicodeScalars {
            if scalar.value >= 0x20 && scalar.value <= 0x7E {
                replacingPresentation = false
                result.unicodeScalars.append(scalar)
            } else if !replacingPresentation {
                result += "[redacted]"
                replacingPresentation = true
            }
        }
        return result
    }

    /// Returns a payload only when the host explicitly enables payload logging.
    public func payload(_ value: String) -> String {
        logsPayloads ? sanitize(value) : "[redacted]"
    }

    /// Sanitizes trusted structured text without exposing payload content by default.
    public func sanitizeStructured(_ value: String) -> String {
        sanitize(value)
    }
}
