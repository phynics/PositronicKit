import Foundation

/// Controls whether a chat turn's diagnostic snapshot is attached to response metadata.
public enum DiagnosticSnapshotPolicy: String, Codable, Sendable, Equatable {
    /// Do not build or attach a diagnostic snapshot.
    case off
    /// Emit ordinary response metadata only. This is equivalent to `off` for snapshot data.
    case metadataOnly
    /// Emit a bounded snapshot with content redacted and truncated.
    case redacted
    /// Emit a bounded snapshot after secret redaction. This requires explicit host opt-in.
    case full
}

/// Runtime policy for diagnostic snapshots attached to ``APIResponseMetadata``.
public struct DiagnosticSnapshotConfiguration: Codable, Sendable, Equatable {
    public let policy: DiagnosticSnapshotPolicy
    public let maxBytes: Int

    public init(
        policy: DiagnosticSnapshotPolicy = .off,
        maxBytes: Int = 64 * 1024
    ) {
        self.policy = policy
        self.maxBytes = max(0, maxBytes)
    }

    public static let `default` = DiagnosticSnapshotConfiguration()
}
