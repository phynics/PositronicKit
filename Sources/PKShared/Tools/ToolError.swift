import ErrorKit
import Foundation

/// Errors related to tool execution and routing.
///
/// v1 error categories:
/// - **malformedArguments**: JSON payload could not be parsed or is not a JSON object.
/// - **schemaMismatch**: Arguments decoded but violated the tool's parameter schema.
/// - **missingArgument**: A required parameter was absent from the arguments dictionary.
/// - **invalidArgument**: A parameter had the wrong type (e.g. string where int was expected).
/// - **toolNotFound**: The requested tool is not registered in any of the timeline's workspaces.
/// - **workspaceNotFound**: The target workspace for the tool could not be resolved.
/// - **executionFailed**: The tool implementation threw during execution.
/// - **requestOriginUnavailable**: The workspace's request origin is not reachable.
/// - **attachedToolsDisallowedOnPrivateTimeline**: Private timelines reject externally hosted tools.
public enum ToolError: PKError, Sendable, Equatable {
    case missingArgument(String)
    case invalidArgument(String, expected: String, got: String)
    case malformedArguments(String)
    case schemaMismatch(String)
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
        case .malformedArguments: return 208
        case .schemaMismatch: return 209
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
        case let .malformedArguments(detail):
            return "The tool call arguments could not be parsed: \(detail)"
        case let .schemaMismatch(detail):
            return "The tool call arguments do not match the tool's schema: \(detail)"
        case let .executionFailed(message):
            return "Failed to execute the tool: \(message)"
        case let .toolNotFound(name):
            return "The requested tool '\(name)' could not be found."
        case .workspaceNotFound:
            return "The target workspace for this tool could not be found."
        case .requestOriginUnavailable:
            return "The request origin associated with this tool is currently unavailable."
        case .attachedToolsDisallowedOnPrivateTimeline:
            return "Private agent timelines do not support additional workspace tools."
        }
    }

    /// Provides a suggested action to resolve the error.
    public var remediation: String? {
        switch self {
        case let .missingArgument(arg):
            return "Check the tool definition and ensure '\(arg)' is provided in the arguments dictionary."
        case let .invalidArgument(arg, expected, got):
            return "Convert the value for '\(arg)' to the expected type (\(expected)). Currently it is \(got)."
        case .malformedArguments:
            return "Check the LLM output for valid JSON argument formatting."
        case .schemaMismatch:
            return "Check the tool's parameter schema and ensure the LLM supplies matching types and required fields."
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
                "Remove additional workspace tools from the agent's configuration."
        }
    }
}
