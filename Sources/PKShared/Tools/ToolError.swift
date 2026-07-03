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
/// - **permissionDenied**: A permissioned tool was not approved by the runtime approval gate.
/// - **unmatchedToolOutput**: An externally submitted tool output does not match a pending call.
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
    case permissionDenied(String)
    case unmatchedToolOutput(String)

    public var errorDomain: String {
        PKErrorDomain.tool
    }

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
        case .permissionDenied: return 210
        case .unmatchedToolOutput: return 211
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
        case let .permissionDenied(name):
            return "The tool '\(name)' requires permission and was not approved."
        case let .unmatchedToolOutput(toolCallId):
            return "The submitted tool output '\(toolCallId)' does not match a pending tool call."
        }
    }

    /// Provides a suggested action to resolve the error.
    public var remediation: String? {
        switch self {
        case let .missingArgument(arg):
            return "Add the required '\(arg)' argument to your tool call and try again."
        case let .invalidArgument(arg, expected, got):
            return "Convert the value for '\(arg)' to the expected type (\(expected)). Currently it is \(got)."
        case .malformedArguments:
            return "Re-emit the tool call with a well-formed JSON object for its arguments " +
                "(quoted keys/strings, no trailing commas), then try again."
        case .schemaMismatch:
            return "Match the tool's parameter schema exactly: supply every required field with the " +
                "correct type, and omit unknown fields."
        case .executionFailed:
            return "Read the error message above, adjust your arguments accordingly, and retry; " +
                "if it keeps failing, try a different tool or approach."
        case let .toolNotFound(name):
            return "'\(name)' is not one of the available tools. Call a tool from the provided list instead."
        case let .workspaceNotFound(id):
            return "Verify that workspace \(id) exists and is currently attached."
        case .requestOriginUnavailable:
            return "Ensure the request origin for this workspace is reachable and registered with the runtime."
        case .attachedToolsDisallowedOnPrivateTimeline:
            return "Only runtime-managed tools are permitted on private timelines. " +
                "Remove additional workspace tools from the agent's configuration."
        case let .permissionDenied(name):
            return "Approve the '\(name)' tool when prompted, or inject an approval gate that " +
                "authorizes it. Permissioned tools never execute without an explicit approval decision."
        case .unmatchedToolOutput:
            return "Submit tool outputs only for tool calls that the runtime previously deferred and has not consumed."
        }
    }
}
