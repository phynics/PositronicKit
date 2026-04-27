import ErrorKit
import Foundation

/// Errors related to tool execution and routing
public enum ToolError: PKError, Sendable, Equatable {
    case missingArgument(String)
    case invalidArgument(String, expected: String, got: String)
    case executionFailed(String)
    case toolNotFound(String)
    case workspaceNotFound(UUID)
    case requestOriginUnavailable
    case attachedToolsDisallowedOnPrivateTimeline

    public var errorDomain: String { PKErrorDomain.tool }

    public var errorCode: Int {
        switch self {
        case .missingArgument: return 201
        case .invalidArgument: return 202
        case .executionFailed: return 203
        case .toolNotFound: return 204
        case .workspaceNotFound: return 205
        case .requestOriginUnavailable: return 206
        case .attachedToolsDisallowedOnPrivateTimeline: return 207
        }
    }

    public var userFriendlyMessage: String {
        switch self {
        case let .missingArgument(arg):
            return "A required argument '\(arg)' is missing from the tool call."
        case let .invalidArgument(arg, expected, got):
            return "The argument '\(arg)' has the wrong type. Expected \(expected) but got \(got)."
        case let .executionFailed(message):
            return "Failed to execute the tool: \(message)"
        case let .toolNotFound(name):
            return "The requested tool '\(name)' could not be found."
        case .workspaceNotFound:
            return "The target workspace for this tool could not be found."
        case .requestOriginUnavailable:
            return "The request origin associated with this tool is currently unavailable."
        case .attachedToolsDisallowedOnPrivateTimeline:
            return "Private agent timelines do not support attached-workspace tools."
        }
    }

    /// Provides a suggested action to resolve the error.
    public var remediation: String? {
        switch self {
        case let .missingArgument(arg):
            return "Check the tool definition and ensure '\(arg)' is provided in the arguments dictionary."
        case let .invalidArgument(arg, expected, got):
            return "Convert the value for '\(arg)' to the expected type (\(expected)). Currently it is \(got)."
        case let .executionFailed(message):
            return "Review the tool logs or debug the tool implementation. Error: \(message)"
        case let .toolNotFound(name):
            return "Ensure the tool '\(name)' is registered in the TimelineToolManager."
        case let .workspaceNotFound(id):
            return "Verify that workspace \(id) exists and is currently attached."
        case .requestOriginUnavailable:
            return "Ensure the request origin for this workspace is reachable and registered with the runtime."
        case .attachedToolsDisallowedOnPrivateTimeline:
            return "Only runtime-managed tools are permitted on private timelines. " +
                "Remove attached-workspace tools from the agent's configuration."
        }
    }
}
