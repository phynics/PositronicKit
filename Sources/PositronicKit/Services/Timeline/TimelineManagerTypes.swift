import ErrorKit
import Foundation
import PKShared

// MARK: - Errors

public enum TimelineError: PKError, Equatable {
    case timelineNotFound
    case unavailable
    case corrupt(String)
    case permissionDenied
    case invalidState(String)

    public var errorDomain: String {
        PKErrorDomain.timeline
    }

    public var errorCode: Int {
        switch self {
        case .timelineNotFound: return 6001
        case .unavailable: return 6002
        case .corrupt: return 6003
        case .permissionDenied: return 6004
        case .invalidState: return 6005
        }
    }

    public var userFriendlyMessage: String {
        switch self {
        case .timelineNotFound:
            return "The requested chat timeline could not be found."
        case .unavailable:
            return "The timeline store is currently unavailable. Please try again."
        case .corrupt:
            return "The timeline data appears to be corrupted. Please contact support."
        case .permissionDenied:
            return "Permission denied when accessing the timeline store."
        case .invalidState:
            return "The timeline is in an invalid state for this operation."
        }
    }

    public var remediation: String? {
        switch self {
        case .unavailable:
            return "Wait a moment and retry the operation."
        case .corrupt:
            return "Contact your administrator to inspect the persistence backend."
        case .permissionDenied:
            return "Verify that the runtime has the required access permissions."
        case .invalidState:
            return nil
        case .timelineNotFound:
            return nil
        }
    }
}

/// A typed record of a best-effort failure that was downgraded rather than thrown.
/// Carries stable error identity and operation metadata so callers and operators can
/// see *what* failed and *why*, rather than observing a silent empty/nil result.
public struct StoreDegradation: Sendable {
    public let operation: String
    public let entityID: String
    public let errorIdentity: ChatEvent.ErrorIdentity?
    public let message: String

    public init(operation: String, entityID: String, error: Error) {
        self.operation = operation
        self.entityID = entityID
        self.errorIdentity = .extracting(from: error)
        self.message = ErrorKit.userFriendlyMessage(for: error)
    }

    public init(operation: String, entityID: String, errorIdentity: ChatEvent.ErrorIdentity?, message: String) {
        self.operation = operation
        self.entityID = entityID
        self.errorIdentity = errorIdentity
        self.message = message
    }

    /// Creates a store degradation using the legacy identifier spelling.
    @available(*, deprecated, message: "Use init(operation:entityID:error:).")
    public init(operation: String, entityId: String, error: Error) {
        self.init(operation: operation, entityID: entityId, error: error)
    }

    /// Creates a store degradation using the legacy identifier spelling.
    @available(*, deprecated, message: "Use init(operation:entityID:errorIdentity:message:).")
    public init(operation: String, entityId: String, errorIdentity: ChatEvent.ErrorIdentity?, message: String) {
        self.init(operation: operation, entityID: entityId, errorIdentity: errorIdentity, message: message)
    }

    /// The entity identifier using the legacy 3.x spelling.
    @available(*, deprecated, renamed: "entityID")
    public var entityId: String { entityID }
}

/// The result of a workspace query, including any best-effort degradations encountered
/// while resolving individual workspaces. The timeline-level store failure is thrown as
/// a `TimelineError` (not collapsed into an empty result); individual workspace fetch
/// failures are collected as `degradations` so the caller can log or surface them.
public struct WorkspaceQueryResult: Sendable {
    public let primary: WorkspaceReference?
    public let attached: [WorkspaceReference]
    public let degradations: [StoreDegradation]

    public init(primary: WorkspaceReference?, attached: [WorkspaceReference], degradations: [StoreDegradation] = []) {
        self.primary = primary
        self.attached = attached
        self.degradations = degradations
    }
}

/// The result of ``TimelineManager/deleteTimelinePermanently(id:)``.
///
/// Permanent deletion is best-effort across multiple stores (timeline row, messages,
/// workspace attachments). When every store succeeds, `isComplete` is `true` and
/// `degradations` is empty. When one or more stores fail, the remaining stores are still
/// attempted and each failure is recorded as a ``StoreDegradation`` so the caller can log,
/// retry, or surface the partial cleanup.
public struct TimelineDeletionResult: Sendable {
    public let timelineID: UUID
    public let degradations: [StoreDegradation]

    /// `true` when every persisted record was removed; `false` when one or more stores failed.
    public var isComplete: Bool { degradations.isEmpty }

    public init(timelineID: UUID, degradations: [StoreDegradation] = []) {
        self.timelineID = timelineID
        self.degradations = degradations
    }

    /// Creates a deletion result using the legacy identifier spelling.
    @available(*, deprecated, message: "Use init(timelineID:degradations:).")
    public init(timelineId: UUID, degradations: [StoreDegradation] = []) {
        self.init(timelineID: timelineId, degradations: degradations)
    }

    /// The timeline identifier using the legacy 3.x spelling.
    @available(*, deprecated, renamed: "timelineID")
    public var timelineId: UUID { timelineID }
}
