import ErrorKit
import Foundation
import MonadShared

// MARK: - Errors

public enum AgentInstanceError: MonadError, Sendable {
    case instanceNotFound(UUID)
    case timelineNotFound(UUID)
    case differentAgentAlreadyAttached(UUID)
    case hasAttachedTimelines(count: Int)
    case nameTooShort(String)
    case descriptionEmpty
    case cannotAttachToPrivateTimeline(UUID)
    case cannotDetachFromOwnPrivateTimeline(UUID)

    public var errorDomain: String { MonadErrorDomain.agent }

    public var errorCode: Int {
        switch self {
        case .instanceNotFound: return 5001
        case .timelineNotFound: return 5002
        case .differentAgentAlreadyAttached: return 5003
        case .hasAttachedTimelines: return 5004
        case .nameTooShort: return 5005
        case .descriptionEmpty: return 5006
        case .cannotAttachToPrivateTimeline: return 5007
        case .cannotDetachFromOwnPrivateTimeline: return 5008
        }
    }

    public var errorDescription: String? {
        switch self {
        case .instanceNotFound(let id):
            return "Agent instance not found: \(id)"
        case .timelineNotFound(let id):
            return "Timeline not found: \(id)"
        case .differentAgentAlreadyAttached(let id):
            return "A different agent (\(id)) is already attached. Detach it first."
        case .hasAttachedTimelines(let count):
            return "Cannot delete: \(count) timeline(s) still attached. Use force=true to override."
        case .nameTooShort(let name):
            return "Agent name '\(name)' is too short (min 3 chars)."
        case .descriptionEmpty:
            return "Agent description cannot be empty."
        case .cannotAttachToPrivateTimeline(let id):
            return "Cannot attach an agent to a private timeline it doesn't own (\(id))."
        case .cannotDetachFromOwnPrivateTimeline(let id):
            return "Cannot detach an agent from its own private timeline (\(id))."
        }
    }

    public var userFriendlyMessage: String {
        switch self {
        case .instanceNotFound(let id):
            return "The requested agent instance \(id.uuidString.prefix(8)) could not be found."
        case .timelineNotFound(let id):
            return "The requested timeline \(id.uuidString.prefix(8)) could not be found."
        case .differentAgentAlreadyAttached(let id):
            return "Timeline already has agent \(id.uuidString.prefix(8)) attached. "
                + "Please detach it before attaching a new one."
        case .hasAttachedTimelines(let count):
            return "This agent is currently active on \(count) timeline(s) and cannot be deleted."
        case .nameTooShort:
            return "Please provide a name with at least 3 characters."
        case .descriptionEmpty:
            return "Please provide a description for the agent."
        case .cannotAttachToPrivateTimeline:
            return "Agents can only be attached to their own private timelines."
        case .cannotDetachFromOwnPrivateTimeline:
            return "An agent must remain attached to its own private timeline."
        }
    }
}
