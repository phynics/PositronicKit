import Foundation
import Logging
import PKShared

// MARK: - Supporting Types

/// The outcome of routing a single tool execution attempt.
public enum ToolExecutionOutcome: Sendable {
    case completed(String)
    case deferredExternally
}

/// A fully parsed tool call from the LLM response, ready for routing.
///
/// This is a runtime-internal routing detail (`package`-scoped): it is produced and consumed inside
/// the chat loop and is not part of the downstream public surface.
package struct ParsedToolCall {
    package let callId: String
    package let name: String
    package let argumentsJSON: String
    /// Arguments decoded once at init time. `nil` when JSON is malformed or not a JSON object.
    package let arguments: [String: AnyCodable]?

    package init(callId: String, name: String, argumentsJSON: String) {
        self.callId = callId
        self.name = name
        self.argumentsJSON = argumentsJSON
        let data = argumentsJSON.data(using: .utf8) ?? Data()
        arguments = try? JSONDecoder().decode([String: AnyCodable].self, from: data)
    }
}

/// Result of handling all pending tool calls in a turn.
///
/// Runtime-internal (`package`-scoped); returned by `handlePendingToolCalls` to the chat loop.
package struct ToolHandlingResult {
    /// Whether any tool calls were deferred for external execution.
    package let hasDeferred: Bool
    /// Provider-neutral tool result messages for runtime-resolved calls.
    package let resolvedToolParams: [LLMMessage]
}

/// Result of processing tool calls from a completed LLM turn.
/// Includes the assistant message (with tool call definitions) and resolved tool results.
///
/// Runtime-internal (`package`-scoped); consumed by the chat loop.
package enum ToolTurnResult {
    /// No tool calls were produced — the turn is complete.
    case noToolCalls
    /// All tool calls were resolved by this runtime; continue the loop with these messages.
    case continueWith([LLMMessage])
    /// At least one tool call was deferred for external execution — stop and wait.
    case deferredExternally
}

// MARK: - ToolRouter

/// Routes tool execution requests to the appropriate handler (local or externally hosted).
///
/// The primary entry point is `handlePendingToolCalls()`, which executes runtime-managed tools
/// immediately (persisting results to the message store) and defers externally hosted tools for
/// async handling. `ChatEngine` calls this after each LLM turn that produces tool calls.
///
/// Public surface is stable across PKARCH-002; the four former inline concerns — workspace
/// resolution, local execution, wall-clock timeout enforcement, and tool progress/completion
/// event projection — are now delegated to `ToolRoutingDecision`, `ToolExecutor`,
/// `ToolTimeoutEnforcer`, and `ToolTurnProjector` respectively.
public actor ToolRouter {
    private let logger = Logger.module(named: "tool-router")

    private let timelineManager: TimelineManager
    private let messageStore: any MessageStoreProtocol
    private let toolExecutionTimeout: TimeInterval
    private let approvalGate: any ToolApprovalGate
    private let executor: ToolExecutor

    public init(
        timelineManager: TimelineManager,
        messageStore: any MessageStoreProtocol,
        toolExecutionTimeout: TimeInterval = 60,
        approvalGate: any ToolApprovalGate = DenyAllToolApprovalGate()
    ) {
        self.timelineManager = timelineManager
        self.messageStore = messageStore
        self.toolExecutionTimeout = toolExecutionTimeout
        self.approvalGate = approvalGate
        self.executor = ToolExecutor(
            approvalGate: approvalGate,
            timeout: toolExecutionTimeout
        )
    }

    // MARK: - Turn-Level API

    /// Processes tool calls from a completed LLM turn.
    ///
    /// Extracts streamed tool call accumulators from `TurnOutputs`, constructs the assistant
    /// message (with tool call definitions for conversation history), executes runtime-managed tools,
    /// and returns a decision for the chat loop.
    func processToolCalls(
        outputs: TurnOutputs,
        timelineId: UUID,
        availableTools: [AnyTool],
        continuation: AsyncThrowingStream<ChatEvent, Error>.Continuation
    ) async throws -> ToolTurnResult {
        let accumulators = await outputs.toolCallAccumulators
        guard !accumulators.isEmpty else { return .noToolCalls }

        let sortedCalls = accumulators.sorted(by: { $0.key < $1.key })

        // Parse into routable tool calls
        let parsedCalls = sortedCalls.map { _, value in
            ParsedToolCall(callId: value.callId, name: value.name, argumentsJSON: value.args)
        }

        // Build the assistant message with tool_calls for conversation history
        let toolCallsParam = sortedCalls.map { _, value in
            LLMToolCall(id: value.callId, name: value.name, arguments: value.args)
        }
        let fullResponse = await outputs.fullResponse
        let assistantParam = LLMMessage(
            role: .assistant,
            content: fullResponse,
            toolCalls: toolCallsParam
        )

        // Route and execute
        let result = try await handlePendingToolCalls(
            timelineId: timelineId,
            calls: parsedCalls,
            availableTools: availableTools,
            continuation: continuation
        )

        if result.hasDeferred { return .deferredExternally }
        return .continueWith([assistantParam] + result.resolvedToolParams)
    }

    // MARK: - Batch Handling

    /// Handles all tool calls produced in an LLM turn.
    ///
    /// - Runtime-managed tools are executed immediately; results are persisted and returned.
    /// - External tools are skipped; the host executes and submits results asynchronously.
    /// - Private timelines may not defer to externally hosted tools — an error is thrown instead.
    package func handlePendingToolCalls(
        timelineId: UUID,
        calls: [ParsedToolCall],
        availableTools: [AnyTool],
        continuation: AsyncThrowingStream<ChatEvent, Error>.Continuation
    ) async throws -> ToolHandlingResult {
        var hasDeferred = false
        var resolvedToolParams: [LLMMessage] = []

        for call in calls {
            let toolRef = ToolRoutingDecision.resolveToolReference(
                for: call,
                availableTools: availableTools
            )

            ToolTurnProjector.projectAttempt(
                call: call,
                toolRef: toolRef,
                continuation: continuation
            )

            do {
                guard let arguments = call.arguments else {
                    throw ToolError.malformedArguments(
                        "Tool '\(call.name)' produced arguments that are not valid JSON or not a JSON object: \(call.argumentsJSON.prefix(100))"
                    )
                }
                let outcome = try await execute(
                    tool: toolRef, arguments: arguments,
                    timelineId: timelineId, availableTools: availableTools
                )
                let param = try await ToolTurnProjector.projectOutcome(
                    outcome,
                    call: call,
                    timelineId: timelineId,
                    logger: logger,
                    messageStore: messageStore,
                    continuation: continuation
                )
                if let param { resolvedToolParams.append(param) }
                if case .deferredExternally = outcome { hasDeferred = true }
            } catch {
                let param = try await ToolTurnProjector.projectError(
                    error,
                    call: call,
                    toolRef: toolRef,
                    timelineId: timelineId,
                    logger: logger,
                    messageStore: messageStore,
                    continuation: continuation
                )
                resolvedToolParams.append(param)
            }
        }

        return ToolHandlingResult(hasDeferred: hasDeferred, resolvedToolParams: resolvedToolParams)
    }

    // MARK: - Core Routing

    /// Routes a single tool call to local or external execution.
    public func execute(
        tool: ToolReference,
        arguments: [String: AnyCodable],
        timelineId: UUID,
        availableTools: [AnyTool]? = nil
    ) async throws -> ToolExecutionOutcome {
        let toolName = ANSIColors.colorize(tool.displayName, color: ANSIColors.brightCyan)
        let sid = ANSIColors.colorize(timelineId.uuidString.prefix(8).lowercased(), color: ANSIColors.dim)

        logger.info("Routing 🛠️ \(toolName) in timeline \(sid)")

        // Strip workspaceID — it's a routing-only concern, not a tool parameter
        var forwardedArguments = arguments
        forwardedArguments.removeValue(forKey: "workspaceID")

        // Dynamic/per-turn tools (passed directly via `availableTools`, e.g. workspace-independent
        // demo tools like `calculator`/`current_datetime`) execute locally unconditionally — they
        // were explicitly handed to this turn by the caller and need no workspace-tool mapping or
        // even an attached workspace to resolve. Without this branch, a timeline with no attached
        // folder workspace (the common case for a fresh conversation) would fail every tool call
        // with `toolNotFound`, even though the correct `AnyTool` was right there in `availableTools`.
        if let dynamicTools = availableTools,
           dynamicTools.contains(where: { $0.toolReference == tool || $0.id == tool.toolId })
        {
            let output = try await executor.execute(
                tool: tool,
                arguments: forwardedArguments,
                lookup: { [timelineManager] in
                    await timelineManager.getToolManager(for: timelineId)
                },
                dynamicTools: dynamicTools
            )
            return .completed(output)
        }

        // resolveWorkspace returns nil when the tool is not registered in any of the
        // timeline's workspaces, or when the timeline has no workspaces at all.
        guard let workspaceId = try await ToolRoutingDecision.resolveWorkspace(
            for: tool,
            in: timelineId,
            arguments: arguments,
            provider: timelineManager,
            logger: logger
        ) else {
            throw ToolError.toolNotFound(tool.displayName)
        }

        guard let workspace = try await timelineManager.getWorkspace(workspaceId) else {
            throw ToolError.workspaceNotFound(workspaceId)
        }

        switch try ToolRoutingDecision.outcomeForWorkspace(
            location: workspace.location,
            timelineIsPrivate: await timelineManager.getTimeline(id: timelineId)?.isPrivate ?? false
        ) {
        case .executeLocally:
            let output = try await executor.execute(
                tool: tool,
                arguments: forwardedArguments,
                lookup: { [timelineManager] in
                    await timelineManager.getToolManager(for: timelineId)
                },
                dynamicTools: availableTools
            )
            return .completed(output)

        case .deferExternally:
            return .deferredExternally
        }
    }
}