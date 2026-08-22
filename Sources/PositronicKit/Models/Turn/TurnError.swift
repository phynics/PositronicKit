import Foundation
import PKContracts

/// Errors produced while validating a facade turn request.
public enum TurnError: PKError, Sendable, Equatable {
    /// The request specified fewer than one permitted model round.
    case invalidMaxModelRounds(Int)
    /// Managed execution requires a durable Agent attachment on the Thread.
    case managedExecutionRequiresAttachedAgent(UUID)
    /// Direct execution is valid only for a detached Thread.
    case directExecutionRequiresDetachedThread(UUID)
    /// The captured Agent identity no longer matches the Thread's attachment at admission.
    case managedExecutionAgentMismatch(threadID: UUID, requestedAgentID: UUID, attachedAgentID: UUID?)

    public var errorDomain: String {
        PKErrorDomain.turn
    }

    public var errorCode: Int {
        switch self {
        case .invalidMaxModelRounds: 9008
        case .managedExecutionRequiresAttachedAgent: 9021
        case .directExecutionRequiresDetachedThread: 9022
        case .managedExecutionAgentMismatch: 9023
        }
    }

    public var userFriendlyMessage: String {
        switch self {
        case let .invalidMaxModelRounds(value):
            "maxModelRounds must be at least 1; received \(value)."
        case let .managedExecutionRequiresAttachedAgent(threadID):
            "Thread \(threadID.uuidString.prefix(8)) has no attached Agent for managed execution."
        case let .directExecutionRequiresDetachedThread(threadID):
            "Thread \(threadID.uuidString.prefix(8)) has an attached Agent and cannot run direct execution."
        case .managedExecutionAgentMismatch:
            "The requested Agent is not the Agent attached to this Thread."
        }
    }

    public var errorDescription: String? {
        switch self {
        case let .invalidMaxModelRounds(value):
            return "maxModelRounds must be at least 1; received \(value)."
        case let .managedExecutionRequiresAttachedAgent(threadID):
            return "Thread \(threadID) has no attached Agent for managed execution."
        case let .directExecutionRequiresDetachedThread(threadID):
            return "Thread \(threadID) has an attached Agent and cannot run direct execution."
        case let .managedExecutionAgentMismatch(threadID, requestedAgentID, attachedAgentID):
            let attachment = attachedAgentID.map { "agent \($0) is attached" } ?? "no Agent is attached"
            return "Agent \(requestedAgentID) is not authorized for thread \(threadID); \(attachment)."
        }
    }

    public var remediation: String? {
        switch self {
        case .invalidMaxModelRounds:
            "Pass a maxModelRounds value greater than or equal to 1."
        case .managedExecutionRequiresAttachedAgent:
            "Attach an Agent to the Thread or use startDirectTurn with explicit context."
        case .directExecutionRequiresDetachedThread:
            "Detach the Agent before using direct execution, or use managed execution."
        case .managedExecutionAgentMismatch:
            "Retry using the Agent currently attached to the Thread."
        }
    }
}
