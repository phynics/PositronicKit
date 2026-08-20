import ErrorKit
import Foundation
import PKContracts
import PKUtilities

// MARK: - Errors

public enum AgentError: PKError, Sendable {
    case agentNotFound(UUID)
    case threadNotFound(UUID)
    case threadAgentMismatch(threadID: UUID, agentID: UUID, attachedAgentID: UUID?)
    case hasAttachedThreads(count: Int)
    case cannotAttachToPrivateThread(UUID)
    case cannotDetachFromOwnPrivateThread(UUID)
    case differentAgentAlreadyAttached(UUID)
    case nameTooShort(String)
    case descriptionEmpty

    public var errorDomain: String { PKErrorDomain.agent }

    public var errorCode: Int {
        switch self {
        case .agentNotFound: return 5001
        case .threadNotFound: return 5002
        case .differentAgentAlreadyAttached: return 5003
        case .threadAgentMismatch: return 5009
        case .hasAttachedThreads: return 5004
        case .nameTooShort: return 5005
        case .descriptionEmpty: return 5006
        case .cannotAttachToPrivateThread: return 5007
        case .cannotDetachFromOwnPrivateThread: return 5008
        }
    }

    public var errorDescription: String? {
        switch self {
        case .agentNotFound(let id):
            return "Agent not found: \(id)"
        case .threadNotFound(let id):
            return "Thread not found: \(id)"
        case .differentAgentAlreadyAttached(let id):
            return "A different agent (\(id)) is already attached. Detach it first."
        case let .threadAgentMismatch(threadID, agentID, attachedAgentID):
            let attachment = attachedAgentID.map { "agent \($0) is attached" } ?? "no agent is attached"
            return "Agent \(agentID) is not attached to thread \(threadID); \(attachment)."
        case .hasAttachedThreads(let count):
            return "Cannot delete: \(count) thread(s) still attached. Use force=true to override."
        case .nameTooShort(let name):
            return "Agent name '\(name)' is too short (min 3 chars)."
        case .descriptionEmpty:
            return "Agent description cannot be empty."
        case .cannotAttachToPrivateThread(let id):
            return "Cannot attach an agent to a private thread it doesn't own (\(id))."
        case .cannotDetachFromOwnPrivateThread(let id):
            return "Cannot detach an agent from its own private thread (\(id))."
        }
    }

    public var userFriendlyMessage: String {
        switch self {
        case .agentNotFound(let id):
            return "The requested agent \(id.uuidString.prefix(8)) could not be found."
        case .threadNotFound(let id):
            return "The requested thread \(id.uuidString.prefix(8)) could not be found."
        case .differentAgentAlreadyAttached(let id):
            return "Thread already has agent \(id.uuidString.prefix(8)) attached. "
                + "Please detach it before attaching a new one."
        case .threadAgentMismatch:
            return "The requested agent is not attached to this thread. Attach it before running the turn."
        case .hasAttachedThreads(let count):
            return "This agent is currently active on \(count) thread(s) and cannot be deleted."
        case .nameTooShort:
            return "Please provide a name with at least 3 characters."
        case .descriptionEmpty:
            return "Please provide a description for the agent."
        case .cannotAttachToPrivateThread:
            return "Agents can only be attached to their own private threads."
        case .cannotDetachFromOwnPrivateThread:
            return "An agent must remain attached to its own private thread."
        }
    }
}
