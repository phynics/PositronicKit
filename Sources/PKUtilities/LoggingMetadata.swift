import Logging
import PKContracts

/// Stable metadata shared by all error log sites.
package enum LoggingMetadata {
    /// Creates structured logging metadata for an error and its correlation identifier.
    package static func makeMetadata(for error: Error, correlationID: String) -> Logger.Metadata {
        let identity = TurnEvent.ErrorIdentity.extracting(from: error)
        return [
            LogKeys.errorDomain: .string(identity?.domain ?? "com.positronickit.unknown"),
            LogKeys.errorCode: .string(String(identity?.code ?? 0)),
            LogKeys.correlationID: .string(correlationID),
        ]
    }

}
