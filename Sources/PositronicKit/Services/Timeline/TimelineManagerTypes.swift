import ErrorKit
import Foundation
import PKContracts

// MARK: - Errors

public enum TimelineError: PKError, Equatable {
    case timelineNotFound
    case unavailable
    case corrupt(String)
    case permissionDenied
    case invalidState(String)
    case noQuarantinedTurn
    /// No cache-exact sibling prefix can be served for the requested Timeline. The associated
    /// reason distinguishes an in-flight Turn from a Timeline that has not retained a final
    /// model round yet. See `TimelineHandle.siblingRequest(appending:responseFormat:generationParameters:)`.
    case siblingPrefixUnavailable(SiblingPrefixUnavailability)

    /// Why a cache-exact sibling prefix was unavailable.
    public enum SiblingPrefixUnavailability: String, Sendable, Equatable {
        /// A Turn is in flight on the Timeline, so the newest round is not final and mixing
        /// rounds is forbidden.
        case turnInFlight
        /// The Timeline has retained no completed final model round yet.
        case noRetainedRound
        /// The runtime was not configured with `retainsSiblingPrefix`.
        case retentionDisabled
    }

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
        case .noQuarantinedTurn: return 6006
        case .siblingPrefixUnavailable: return 6007
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
        case .noQuarantinedTurn:
            return "This conversation has no quarantined Turn to release."
        case let .siblingPrefixUnavailable(reason):
            switch reason {
            case .turnInFlight:
                return "A Turn is still in flight on this conversation. Retry the sibling request after it completes."
            case .noRetainedRound:
                return "This conversation has no completed model round whose prefix can be reused."
            case .retentionDisabled:
                return "Sibling-prefix retention is not enabled for this runtime."
            }
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
        case .noQuarantinedTurn:
            return "Send a new message to refresh the conversation state."
        case let .siblingPrefixUnavailable(reason):
            switch reason {
            case .turnInFlight:
                return "Wait for the in-flight Turn to reach a terminal state, then retry."
            case .noRetainedRound:
                return "Complete a Turn on this conversation before issuing a sibling request."
            case .retentionDisabled:
                return "Construct the runtime with `RuntimeConfiguration(retainsSiblingPrefix: true)`."
            }
        }
    }
}

/// A typed record of a best-effort failure that was downgraded rather than thrown.
/// Carries stable error identity and operation metadata so callers and operators can
/// see *what* failed and *why*, rather than observing a silent empty/nil result.
public struct StoreDegradation: Sendable {
    public let operation: String
    public let entityID: String
    public let errorIdentity: ErrorIdentity?
    public let message: String

    public init(operation: String, entityID: String, error: Error) {
        self.operation = operation
        self.entityID = entityID
        self.errorIdentity = .extracting(from: error)
        self.message = ErrorKit.userFriendlyMessage(for: error)
    }

    public init(operation: String, entityID: String, errorIdentity: ErrorIdentity?, message: String) {
        self.operation = operation
        self.entityID = entityID
        self.errorIdentity = errorIdentity
        self.message = message
    }
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

/// The result of the internal permanent-timeline deletion operation.
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
}
