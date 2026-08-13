import ErrorKit
import Foundation
import PKShared
import PKUtilities

// MARK: - Errors

public enum AgentInstanceError: PKError, Sendable {
    case instanceNotFound(UUID)
    case threadNotFound(UUID)
    case threadAgentMismatch(threadID: UUID, agentInstanceID: UUID, attachedAgentInstanceID: UUID?)
    case hasAttachedThreads(count: Int)
    case cannotAttachToPrivateThread(UUID)
    case cannotDetachFromOwnPrivateThread(UUID)

    @available(*, deprecated, message: "Timeline APIs are deprecated and will be removed in v4. Use the corresponding Thread API instead.")
    case timelineNotFound(UUID)
    case differentAgentAlreadyAttached(UUID)
    @available(*, deprecated, message: "Timeline APIs are deprecated and will be removed in v4. Use the corresponding Thread API instead.")
    case timelineAgentMismatch(timelineID: UUID, agentInstanceID: UUID, attachedAgentInstanceID: UUID?)
    @available(*, deprecated, message: "Timeline APIs are deprecated and will be removed in v4. Use the corresponding Thread API instead.")
    case hasAttachedTimelines(count: Int)
    case nameTooShort(String)
    case descriptionEmpty
    @available(*, deprecated, message: "Timeline APIs are deprecated and will be removed in v4. Use the corresponding Thread API instead.")
    case cannotAttachToPrivateTimeline(UUID)
    @available(*, deprecated, message: "Timeline APIs are deprecated and will be removed in v4. Use the corresponding Thread API instead.")
    case cannotDetachFromOwnPrivateTimeline(UUID)

    public var errorDomain: String { PKErrorDomain.agent }

    public var errorCode: Int {
        switch self {
        case .instanceNotFound: return 5001
        case .threadNotFound, .timelineNotFound: return 5002
        case .differentAgentAlreadyAttached: return 5003
        case .threadAgentMismatch, .timelineAgentMismatch: return 5009
        case .hasAttachedThreads, .hasAttachedTimelines: return 5004
        case .nameTooShort: return 5005
        case .descriptionEmpty: return 5006
        case .cannotAttachToPrivateThread, .cannotAttachToPrivateTimeline: return 5007
        case .cannotDetachFromOwnPrivateThread, .cannotDetachFromOwnPrivateTimeline: return 5008
        }
    }

    public var errorDescription: String? {
        switch self {
        case .instanceNotFound(let id):
            return "Agent instance not found: \(id)"
        case .threadNotFound(let id), .timelineNotFound(let id):
            return "Timeline not found: \(id)"
        case .differentAgentAlreadyAttached(let id):
            return "A different agent (\(id)) is already attached. Detach it first."
        case let .threadAgentMismatch(timelineID, agentInstanceID, attachedAgentInstanceID),
             let .timelineAgentMismatch(timelineID, agentInstanceID, attachedAgentInstanceID):
            let attachment = attachedAgentInstanceID.map { "agent \($0) is attached" } ?? "no agent is attached"
            return "Agent instance \(agentInstanceID) is not attached to timeline \(timelineID); \(attachment)."
        case .hasAttachedThreads(let count), .hasAttachedTimelines(let count):
            return "Cannot delete: \(count) timeline(s) still attached. Use force=true to override."
        case .nameTooShort(let name):
            return "Agent name '\(name)' is too short (min 3 chars)."
        case .descriptionEmpty:
            return "Agent description cannot be empty."
        case .cannotAttachToPrivateThread(let id), .cannotAttachToPrivateTimeline(let id):
            return "Cannot attach an agent to a private timeline it doesn't own (\(id))."
        case .cannotDetachFromOwnPrivateThread(let id), .cannotDetachFromOwnPrivateTimeline(let id):
            return "Cannot detach an agent from its own private timeline (\(id))."
        }
    }

    public var userFriendlyMessage: String {
        switch self {
        case .instanceNotFound(let id):
            return "The requested agent instance \(id.uuidString.prefix(8)) could not be found."
        case .threadNotFound(let id), .timelineNotFound(let id):
            return "The requested timeline \(id.uuidString.prefix(8)) could not be found."
        case .differentAgentAlreadyAttached(let id):
            return "Timeline already has agent \(id.uuidString.prefix(8)) attached. "
                + "Please detach it before attaching a new one."
        case .threadAgentMismatch, .timelineAgentMismatch:
            return "The requested agent is not attached to this timeline. Attach it before running the turn."
        case .hasAttachedThreads(let count), .hasAttachedTimelines(let count):
            return "This agent is currently active on \(count) timeline(s) and cannot be deleted."
        case .nameTooShort:
            return "Please provide a name with at least 3 characters."
        case .descriptionEmpty:
            return "Please provide a description for the agent."
        case .cannotAttachToPrivateThread, .cannotAttachToPrivateTimeline:
            return "Agents can only be attached to their own private timelines."
        case .cannotDetachFromOwnPrivateThread, .cannotDetachFromOwnPrivateTimeline:
            return "An agent must remain attached to its own private timeline."
        }
    }
}
