import Foundation
import PKContracts

/// Errors produced while validating a facade turn request.
public enum TurnError: PKError, Sendable, Equatable {
    /// The request specified fewer than one permitted model round.
    case invalidMaxModelRounds(Int)
    /// Managed execution requires a durable Agent attachment on the Timeline.
    case managedExecutionRequiresAttachedAgent(UUID)
    /// Direct execution is valid only for a detached Timeline.
    case directExecutionRequiresDetachedTimeline(UUID)
    /// The captured Agent identity no longer matches the Timeline's attachment at admission.
    case managedExecutionAgentMismatch(timelineID: UUID, requestedAgentID: UUID, attachedAgentID: UUID?)

    public var errorDomain: String {
        PKErrorDomain.turn
    }

    public var errorCode: Int {
        switch self {
        case .invalidMaxModelRounds: 9008
        case .managedExecutionRequiresAttachedAgent: 9021
        case .directExecutionRequiresDetachedTimeline: 9022
        case .managedExecutionAgentMismatch: 9023
        }
    }

    public var userFriendlyMessage: String {
        switch self {
        case let .invalidMaxModelRounds(value):
            "maxModelRounds must be at least 1; received \(value)."
        case let .managedExecutionRequiresAttachedAgent(timelineID):
            "Timeline \(timelineID.uuidString.prefix(8)) has no attached Agent for managed execution."
        case let .directExecutionRequiresDetachedTimeline(timelineID):
            "Timeline \(timelineID.uuidString.prefix(8)) has an attached Agent and cannot run direct execution."
        case .managedExecutionAgentMismatch:
            "The requested Agent is not the Agent attached to this Timeline."
        }
    }

    public var errorDescription: String? {
        switch self {
        case let .invalidMaxModelRounds(value):
            return "maxModelRounds must be at least 1; received \(value)."
        case let .managedExecutionRequiresAttachedAgent(timelineID):
            return "Timeline \(timelineID) has no attached Agent for managed execution."
        case let .directExecutionRequiresDetachedTimeline(timelineID):
            return "Timeline \(timelineID) has an attached Agent and cannot run direct execution."
        case let .managedExecutionAgentMismatch(timelineID, requestedAgentID, attachedAgentID):
            let attachment = attachedAgentID.map { "agent \($0) is attached" } ?? "no Agent is attached"
            return "Agent \(requestedAgentID) is not authorized for timeline \(timelineID); \(attachment)."
        }
    }

    public var remediation: String? {
        switch self {
        case .invalidMaxModelRounds:
            "Pass a maxModelRounds value greater than or equal to 1."
        case .managedExecutionRequiresAttachedAgent:
            "Attach an Agent to the Timeline or use startDirectTurn with explicit context."
        case .directExecutionRequiresDetachedTimeline:
            "Detach the Agent before using direct execution, or use managed execution."
        case .managedExecutionAgentMismatch:
            "Retry using the Agent currently attached to the Timeline."
        }
    }
}
