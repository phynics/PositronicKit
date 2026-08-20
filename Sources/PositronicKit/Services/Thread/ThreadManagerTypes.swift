import ErrorKit
import Foundation
import PKContracts

// MARK: - Errors

public enum ThreadError: PKError, Equatable {
    case threadNotFound
    case unavailable
    case corrupt(String)
    case permissionDenied
    case invalidState(String)

    public var errorDomain: String {
        PKErrorDomain.thread
    }

    public var errorCode: Int {
        switch self {
        case .threadNotFound: return 6001
        case .unavailable: return 6002
        case .corrupt: return 6003
        case .permissionDenied: return 6004
        case .invalidState: return 6005
        }
    }

    public var userFriendlyMessage: String {
        switch self {
        case .threadNotFound:
            return "The requested chat thread could not be found."
        case .unavailable:
            return "The thread store is currently unavailable. Please try again."
        case .corrupt:
            return "The thread data appears to be corrupted. Please contact support."
        case .permissionDenied:
            return "Permission denied when accessing the thread store."
        case .invalidState:
            return "The thread is in an invalid state for this operation."
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
        case .threadNotFound:
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
    public let errorIdentity: TurnEvent.ErrorIdentity?
    public let message: String

    public init(operation: String, entityID: String, error: Error) {
        self.operation = operation
        self.entityID = entityID
        self.errorIdentity = .extracting(from: error)
        self.message = ErrorKit.userFriendlyMessage(for: error)
    }

    public init(operation: String, entityID: String, errorIdentity: TurnEvent.ErrorIdentity?, message: String) {
        self.operation = operation
        self.entityID = entityID
        self.errorIdentity = errorIdentity
        self.message = message
    }
}

/// The result of a workspace query, including any best-effort degradations encountered
/// while resolving individual workspaces. The thread-level store failure is thrown as
/// a `ThreadError` (not collapsed into an empty result); individual workspace fetch
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

/// The result of ``ThreadManager/deleteThreadPermanently(id:)``.
///
/// Permanent deletion is best-effort across multiple stores (thread row, messages,
/// workspace attachments). When every store succeeds, `isComplete` is `true` and
/// `degradations` is empty. When one or more stores fail, the remaining stores are still
/// attempted and each failure is recorded as a ``StoreDegradation`` so the caller can log,
/// retry, or surface the partial cleanup.
public struct ThreadDeletionResult: Sendable {
    public let threadID: UUID
    public let degradations: [StoreDegradation]

    /// `true` when every persisted record was removed; `false` when one or more stores failed.
    public var isComplete: Bool { degradations.isEmpty }

    public init(threadID: UUID, degradations: [StoreDegradation] = []) {
        self.threadID = threadID
        self.degradations = degradations
    }
}
