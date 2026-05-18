import Dependencies
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
public struct ParsedToolCall: Sendable {
    public let callId: String
    public let name: String
    public let argumentsJSON: String
    /// Arguments decoded once at init time. `nil` when JSON is malformed or not a JSON object.
    public let arguments: [String: AnyCodable]?

    public init(callId: String, name: String, argumentsJSON: String) {
        self.callId = callId
        self.name = name
        self.argumentsJSON = argumentsJSON
        let data = argumentsJSON.data(using: .utf8) ?? Data()
        arguments = try? JSONDecoder().decode([String: AnyCodable].self, from: data)
    }
}

/// Result of handling all pending tool calls in a turn.
public struct ToolHandlingResult: Sendable {
    /// Whether any tool calls were deferred for external execution.
    public let hasDeferred: Bool
    /// Provider-neutral tool result messages for runtime-resolved calls.
    public let resolvedToolParams: [LLMMessage]
}

/// Result of processing tool calls from a completed LLM turn.
/// Includes the assistant message (with tool call definitions) and resolved tool results.
public enum ToolTurnResult: Sendable {
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
/// Despite the name, this actor currently owns more than lookup-only routing:
///
/// - tool-call normalization for a completed turn
/// - routing decisions between runtime-managed and externally attached execution
/// - local execution coordination
/// - persistence of tool outputs as conversation messages
/// - projection of tool progress/completion events back into the chat stream
///
/// That broader responsibility is intentional for now so the chat loop has a single runtime seam
/// for tool continuation policy. If this area is refactored later, those behaviors should remain
/// pinned by tests rather than being silently redistributed.
public actor ToolRouter {
    private let logger = Logger.module(named: "com.positronickit.core.tools")

    @Dependency(\.timelineManager) private var timelineManager
    @Dependency(\.messageStore) private var messageStore

    public init() {}

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
    public func handlePendingToolCalls(
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

            continuation.yield(.toolProgress(
                toolCallId: call.callId,
                status: .attempting(name: call.name, reference: toolRef)
            ))

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

        // resolveWorkspace returns nil when the tool is not registered in any of the
        // timeline's workspaces, or when the timeline has no workspaces at all.
        guard let workspaceId = try await resolveWorkspace(for: tool, in: timelineId, arguments: arguments) else {
            throw ToolError.toolNotFound(tool.displayName)
        }

        // Strip workspaceID — it's a routing-only concern, not a tool parameter
        var forwardedArguments = arguments
        forwardedArguments.removeValue(forKey: "workspaceID")

        guard let workspace = try await timelineManager.getWorkspace(workspaceId) else {
            throw ToolError.workspaceNotFound(workspaceId)
        }

        switch try ToolRoutingDecision.outcomeForWorkspace(
            location: workspace.location,
            timelineIsPrivate: await timelineManager.getTimeline(id: timelineId)?.isPrivate ?? false
        ) {
        case .executeLocally:
            let output = try await executeLocally(
                tool: tool,
                arguments: forwardedArguments,
                timelineId: timelineId,
                availableTools: availableTools
            )
            return .completed(output)

        case .deferExternally:
            return .deferredExternally
        }
    }

    // MARK: - Private Helpers

    private func resolveWorkspace(
        for tool: ToolReference,
        in timelineId: UUID,
        arguments: [String: AnyCodable]
    ) async throws -> UUID? {
        let workspaces = await timelineManager.getWorkspaces(for: timelineId)
        guard let wsList = workspaces else { return nil }

        let candidates = ([wsList.primary].compactMap { $0?.id }) + wsList.attached.map { $0.id }

        // Check for explicit intent in arguments
        if let explicitIdString = arguments["workspaceID"]?.value as? String,
           let explicitId = UUID(uuidString: explicitIdString.trimmingCharacters(in: .whitespacesAndNewlines)) {
            guard candidates.contains(explicitId) else {
                logger.warning("Requested workspaceID \(explicitId) not found in timeline context. Falling back to default resolution.")
                return try await timelineManager.findWorkspaceForTool(tool, in: candidates)
            }

            logger.debug("Routing to explicitly requested workspace: \(explicitId)")
            return explicitId
        }

        return try await timelineManager.findWorkspaceForTool(tool, in: candidates)
    }

    private func executeLocally(
        tool: ToolReference,
        arguments: [String: AnyCodable],
        timelineId: UUID,
        availableTools: [AnyTool]? = nil
    ) async throws -> String {
        let toolName = ANSIColors.colorize(tool.displayName, color: ANSIColors.brightCyan)
        logger.info("Executing locally: \(toolName)")

        guard let toolManager = await timelineManager.getToolManager(for: timelineId) else {
            throw ToolError.toolNotFound(tool.displayName)
        }

        var toolList = await toolManager.getAvailableTools()
        if let dynamicTools = availableTools {
            // Dynamic tools take priority; exclude static tools with the same ID.
            let dynamicIds = Set(dynamicTools.map { $0.id })
            toolList = dynamicTools + toolList.filter { !dynamicIds.contains($0.id) }
        }

        guard let resolvedTool = toolList.first(where: {
            $0.toolReference == tool || $0.id == tool.toolId
        }) else {
            throw ToolError.toolNotFound(tool.displayName)
        }

        let params = arguments.toAnyDictionary

        let result = try await resolvedTool.execute(parameters: params)
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
