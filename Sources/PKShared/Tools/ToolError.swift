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
/// - **executionFailed**: The tool implementation threw during execution, or a side-effect-free
///   tool was abandoned cleanly after a wall-clock timeout.
/// - **timedOutButMayStillBeRunning**: A mutating/external-process tool was abandoned after a
///   wall-clock timeout; the tool may still be executing out-of-band and retrying may duplicate
///   side effects (PKRR-004).
/// - **requestOriginUnavailable**: The workspace's request origin is not reachable.
/// - **attachedToolsDisallowedOnPrivateTimeline**: Private timelines reject externally hosted tools.
/// - **permissionDenied**: A permissioned tool was not approved by the runtime approval gate.
/// - **unmatchedToolOutput**: An externally submitted tool output does not match a pending call.
/// - **invalidWorkspaceID**: The `workspaceID` argument was present but not a valid UUID string
///   (PKRR-015 fail-closed).
public enum ToolError: PKError, Sendable, Equatable {
    case missingArgument(String)
    case invalidArgument(String, expected: String, got: String)
    case malformedArguments(String)
    case schemaMismatch(String)
    case executionFailed(String)
    case timedOutButMayStillBeRunning(timeout: TimeInterval)
    case toolNotFound(String)
    case workspaceNotFound(UUID)
    case requestOriginUnavailable
    case attachedToolsDisallowedOnPrivateTimeline
    case permissionDenied(String)
    case unmatchedToolOutput(String)
    case invalidWorkspaceID(String)

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
        case .timedOutButMayStillBeRunning: return 212
        case .toolNotFound: return 204
        case .workspaceNotFound: return 205
        case .requestOriginUnavailable: return 206
        case .attachedToolsDisallowedOnPrivateTimeline: return 207
        case .permissionDenied: return 210
        case .unmatchedToolOutput: return 211
        case .invalidWorkspaceID: return 213
        }
    }

    /// `permissionDenied` and `attachedToolsDisallowedOnPrivateTimeline` represent
    /// blocked/approval/disallowed conditions — deliberate permission or access gates
    /// refusing execution, not model or provider failures.
    public var isBlocked: Bool {
        switch self {
        case .permissionDenied, .attachedToolsDisallowedOnPrivateTimeline:
            return true
        default:
            return false
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
        case let .timedOutButMayStillBeRunning(timeout):
            return "Tool execution timed out after \(ToolError.timeoutDescription(timeout)) and may still be running. The tool mutates state, so cancellation is not termination — retrying may duplicate side effects."
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
        case let .invalidWorkspaceID(value):
            return "The 'workspaceID' argument '\(value)' is not a valid UUID string."
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
        case .timedOutButMayStillBeRunning:
            return "The tool may still be executing out-of-band. Do not blindly retry — wait for " +
                "confirmation that the previous attempt finished (or check the affected state " +
                "directly) before calling the tool again, otherwise writes, commands, payments, " +
                "or remote operations may be duplicated."
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
        case .invalidWorkspaceID:
            return "Provide a valid UUID string for 'workspaceID' that matches one of the workspaces " +
                "attached to the current timeline, or omit it to use automatic workspace routing."
        }
    }

    /// Formats a timeout for human-readable messages: integers render without a decimal,
    /// fractional timeouts keep their decimal representation. Shared by
    /// `ToolTimeoutEnforcer` and the `timedOutButMayStillBeRunning` message so the
    /// timeout wording is consistent across the clean-timeout and may-still-be-running
    /// terminal states. Overflow-safe: a finite whole number larger than `Int.max` renders
    /// via the fallback `Double` path rather than trapping on `Int` conversion.
    public static func timeoutDescription(_ timeout: TimeInterval) -> String {
        if timeout.isFinite,
           timeout.rounded() == timeout,
           timeout <= TimeInterval(Int.max),
           timeout >= TimeInterval(Int.min)
        {
            return "\(Int(timeout)) seconds"
        }
        return "\(timeout) seconds"
    }
}
