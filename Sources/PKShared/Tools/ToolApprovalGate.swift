import Foundation

/// The decision returned when a permissioned tool call is presented for approval.
public enum ToolApprovalDecision: Sendable, Equatable {
    /// The tool call may proceed to execution.
    case approve
    /// The tool call must not execute.
    case deny
}

/// Gate consulted at the runtime execution sink before any tool whose
/// ``Tool/requiresPermission`` is `true` runs.
///
/// `ToolRouter` calls ``requestApproval(tool:arguments:)`` for every permissioned tool — for both
/// structured provider tool calls and text-fallback `<tool_call>` calls, since both converge on the
/// same local-execution path. Implementations present the call to the user (or apply a policy) and
/// return a decision; a `.deny` (or any non-`.approve`) result blocks execution with
/// ``ToolError/permissionDenied(_:)``.
///
/// The default gate wired into `ToolRouter` is ``DenyAllToolApprovalGate``: absent an explicit
/// approval path, permissioned tools are blocked rather than silently executed. Hosts that expose
/// permissioned tools must inject a gate that returns `.approve` for sanctioned calls (e.g. a
/// UI-bridging approver), or an ``AllowAllToolApprovalGate`` when approval is delegated elsewhere.
public protocol ToolApprovalGate: Sendable {
    /// Returns the approval decision for a permissioned tool call.
    ///
    /// - Parameters:
    ///   - tool: The resolved tool about to execute. ``Tool/requiresPermission`` is always `true` here.
    ///   - arguments: The decoded arguments the tool will run with (routing-only keys already stripped).
    func requestApproval(tool: AnyTool, arguments: [String: AnyCodable]) async -> ToolApprovalDecision
}

/// Default gate: denies every permissioned tool call.
///
/// Used as `ToolRouter`'s default so a permissioned tool is never executed without an explicit,
/// deliberately-injected approval path. A host that wants permissioned tools to run must inject a
/// concrete gate instead of relying on this one.
public struct DenyAllToolApprovalGate: ToolApprovalGate {
    public init() {}
    public func requestApproval(
        tool _: AnyTool,
        arguments _: [String: AnyCodable]
    ) async -> ToolApprovalDecision {
        .deny
    }
}

/// Gate that approves every permissioned tool call.
///
/// For hosts that have already enforced approval upstream, or that intentionally trust all exposed
/// tools (e.g. a fully sandboxed/jailed tool set). Selecting this is an explicit decision to bypass
/// the runtime gate, never the default.
public struct AllowAllToolApprovalGate: ToolApprovalGate {
    public init() {}
    public func requestApproval(
        tool _: AnyTool,
        arguments _: [String: AnyCodable]
    ) async -> ToolApprovalDecision {
        .approve
    }
}
