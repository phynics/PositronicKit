import Foundation
import Logging
import PKShared

/// Local tool execution: approval-gate check, tool-manager lookup, dynamic-tool priority merge,
/// dispatch to the concrete `AnyTool`, and delegation to `ToolTimeoutEnforcer`.
///
/// Extracted from `ToolRouter.executeLocally` (PKARCH-002) so the local-execution contract has its
/// own testable surface. The executor is `package`-internal; `ToolRouter` remains the public seam
/// and delegates here. The executor does NOT know about workspace resolution or local-vs-external
/// routing — that stays in `ToolRouter.execute` per the ticket's executor/router split.
///
/// The tool-manager lookup is injected as a closure so the executor doesn't depend on
/// `TimelineManager` directly; tests can substitute a fake that returns a pre-built
/// `TimelineToolManager`.
package struct ToolExecutor: Sendable {
    package let approvalGate: any ToolApprovalGate
    package let timeout: TimeInterval
    package let sleep: @Sendable (UInt64) async throws -> Void
    package let logger: Logger

    package init(
        approvalGate: any ToolApprovalGate,
        timeout: TimeInterval,
        sleep: @Sendable @escaping (UInt64) async throws -> Void = ToolTimeoutEnforcer.defaultSleep,
        logger: Logger = Logger.module(named: "tool-executor")
    ) {
        self.approvalGate = approvalGate
        self.timeout = timeout
        self.sleep = sleep
        self.logger = logger
    }

    /// Resolves and executes a tool locally.
    ///
    /// - Parameters:
    ///   - tool: The tool reference to resolve inside the merged tool list.
    ///   - arguments: Decoded arguments. `workspaceID` is stripped before dispatch (it is a
    ///     routing-only concern owned by `ToolRouter`/`ToolRoutingDecision`).
    ///   - lookup: Closure returning the `TimelineToolManager` to read the static tool list from,
    ///     or `nil` if no tool manager is cached for this timeline.
    ///   - dynamicTools: Optional per-turn tools passed directly by the caller; they take priority
    ///     over static tools with the same id.
    /// - Returns: The tool's output string.
    /// - Throws: `ToolError.toolNotFound` if the tool can't be resolved,
    ///   `ToolError.permissionDenied` if the approval gate denies a permissioned tool,
    ///   `ToolError.executionFailed` for tool-body or timeout failures.
    package func execute(
        tool: ToolReference,
        arguments: [String: AnyCodable],
        lookup: @Sendable () async throws -> (TimelineToolManager?),
        dynamicTools: [AnyTool]?
    ) async throws -> String {
        let toolName = ANSIColors.colorize(tool.displayName, color: ANSIColors.brightCyan)
        logger.info("Executing locally: \(toolName)")

        guard let toolManager = try await lookup() else {
            throw ToolError.toolNotFound(tool.displayName)
        }

        var toolList = await toolManager.getAvailableTools()
        if let dynamicTools {
            // Dynamic tools take priority; exclude static tools with the same ID.
            let dynamicIds = Set(dynamicTools.map { $0.id })
            toolList = dynamicTools + toolList.filter { !dynamicIds.contains($0.id) }
        }

        guard let resolvedTool = toolList.first(where: {
            $0.toolReference == tool || $0.id == tool.toolId
        }) else {
            throw ToolError.toolNotFound(tool.displayName)
        }

        // Approval gate: a tool that declares `requiresPermission` must not execute until the
        // injected gate returns `.approve`. This is the single runtime execution sink — both
        // structured provider tool calls and text-fallback `${tool}` calls reach it — so the
        // approval contract holds regardless of how the call was produced (YAK-31). Non-permissioned
        // tools skip the gate entirely.
        if resolvedTool.requiresPermission {
            let decision = await approvalGate.requestApproval(tool: resolvedTool, arguments: arguments)
            guard decision == .approve else {
                logger.warning("Permission denied for \(toolName)")
                throw ToolError.permissionDenied(resolvedTool.name)
            }
        }

        let result = try await ToolTimeoutEnforcer.execute(
            resolvedTool,
            arguments: arguments,
            timeout: timeout,
            sleep: sleep
        )
        if result.success {
            logger.info("Success: \(toolName)")
            return result.output
        } else {
            let errorMsg = result.error ?? "Unknown error"
            logger.error("Failed: \(toolName) - \(errorMsg)")
            throw ToolError.executionFailed(errorMsg)
        }
    }
}