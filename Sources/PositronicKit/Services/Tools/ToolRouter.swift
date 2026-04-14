import Dependencies
import ErrorKit
import Foundation
import Logging
import PKShared
import OpenAI

// MARK: - Supporting Types

/// The outcome of routing a single tool execution attempt.
public enum ToolExecutionOutcome: Sendable {
    case completed(String)
    case deferredToClient
}

/// A fully parsed tool call from the LLM response, ready for routing.
public struct ParsedToolCall: Sendable {
    public let callId: String
    public let name: String
    public let argumentsJSON: String
    /// Arguments decoded once at init time. Malformed JSON silently produces an empty dictionary.
    public let arguments: [String: AnyCodable]

    public init(callId: String, name: String, argumentsJSON: String) {
        self.callId = callId
        self.name = name
        self.argumentsJSON = argumentsJSON
        let data = argumentsJSON.data(using: .utf8) ?? Data()
        arguments = (try? JSONDecoder().decode([String: AnyCodable].self, from: data)) ?? [:]
    }
}

/// Result of handling all pending tool calls in a turn.
public struct ToolHandlingResult: Sendable {
    /// Whether any tool calls were deferred to the client for execution.
    public let hasDeferred: Bool
    /// OpenAI-format tool result messages for server-resolved calls (for LLM context continuation).
    public let resolvedToolParams: [ChatQuery.ChatCompletionMessageParam]
}

/// Result of processing tool calls from a completed LLM turn.
/// Includes the assistant message (with tool call definitions) and resolved tool results.
public enum ToolTurnResult: Sendable {
    /// No tool calls were produced — the turn is complete.
    case noToolCalls
    /// All tool calls were resolved server-side; continue the loop with these messages.
    case continueWith([ChatQuery.ChatCompletionMessageParam])
    /// At least one tool call was deferred to the client — stop and wait.
    case deferredToClient
}

// MARK: - ToolRouter

/// Routes tool execution requests to the appropriate handler (local or remote).
///
/// The primary entry point is `handlePendingToolCalls()`, which executes server-side tools
/// immediately (persisting results to the message store) and defers client-side tools for
/// async handling. `ChatEngine` calls this after each LLM turn that produces tool calls.
public actor ToolRouter {
    private let logger = Logger.module(named: "com.positronickit.core.tools")

    @Dependency(\.timelineManager) private var timelineManager
    @Dependency(\.messageStore) private var messageStore

    public init() {}

    // MARK: - Turn-Level API

    /// Processes tool calls from a completed LLM turn.
    ///
    /// Extracts streamed tool call accumulators from `TurnOutputs`, constructs the assistant
    /// message (with tool call definitions for conversation history), executes server-side tools,
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
            ChatQuery.ChatCompletionMessageParam.AssistantMessageParam.ToolCallParam(
                id: value.callId, function: .init(arguments: value.args, name: value.name)
            )
        }
        let fullResponse = await outputs.fullResponse
        let assistantParam = ChatQuery.ChatCompletionMessageParam.assistant(
            .init(content: .textContent(.init(fullResponse)), toolCalls: toolCallsParam)
        )

        // Route and execute
        let result = try await handlePendingToolCalls(
            timelineId: timelineId,
            calls: parsedCalls,
            availableTools: availableTools,
            continuation: continuation
        )

        if result.hasDeferred { return .deferredToClient }
        return .continueWith([assistantParam] + result.resolvedToolParams)
    }

    // MARK: - Batch Handling

    /// Handles all tool calls produced in an LLM turn.
    ///
    /// - Server-side tools are executed immediately; results are persisted and returned.
    /// - Client-side tools are skipped; the client executes and submits results asynchronously.
    /// - Private timelines may not defer to client — an error is thrown instead.
    public func handlePendingToolCalls(
        timelineId: UUID,
        calls: [ParsedToolCall],
        availableTools: [AnyTool],
        continuation: AsyncThrowingStream<ChatEvent, Error>.Continuation
    ) async throws -> ToolHandlingResult {
        var hasDeferred = false
        var resolvedToolParams: [ChatQuery.ChatCompletionMessageParam] = []

        for call in calls {
            let toolRef = availableTools.first(where: { $0.id == call.name })?.toolReference
                ?? ToolReference.known(id: call.name)

            continuation.yield(.toolProgress(
                toolCallId: call.callId,
                status: .attempting(name: call.name, reference: toolRef)
            ))

            do {
                let outcome = try await execute(
                    tool: toolRef, arguments: call.arguments,
                    timelineId: timelineId, availableTools: availableTools
                )
                let param = try await handleOutcome(
                    outcome, call: call, toolRef: toolRef,
                    timelineId: timelineId, continuation: continuation
                )
                if let param { resolvedToolParams.append(param) }
                if case .deferredToClient = outcome { hasDeferred = true }
            } catch {
                let param = try await handleToolError(
                    error, call: call, toolRef: toolRef,
                    timelineId: timelineId, continuation: continuation
                )
                resolvedToolParams.append(param)
            }
        }

        return ToolHandlingResult(hasDeferred: hasDeferred, resolvedToolParams: resolvedToolParams)
    }

    // MARK: - Outcome Handling

    private func handleOutcome(
        _ outcome: ToolExecutionOutcome,
        call: ParsedToolCall,
        toolRef _: ToolReference,
        timelineId: UUID,
        continuation: AsyncThrowingStream<ChatEvent, Error>.Continuation
    ) async throws -> ChatQuery.ChatCompletionMessageParam? {
        let toolDisplayName = ANSIColors.colorize(call.name, color: ANSIColors.brightCyan)
        switch outcome {
        case let .completed(output):
            logger.info("Tool \(toolDisplayName) succeeded")
            continuation.yield(.toolCompleted(toolCallId: call.callId, status: .success(ToolResult.success(output))))
            try await messageStore.saveMessage(
                ConversationMessage(timelineId: timelineId, role: .tool, content: output, toolCallId: call.callId)
            )
            return .tool(.init(content: .textContent(.init(output)), toolCallId: call.callId))

        case .deferredToClient:
            logger.info("Tool \(toolDisplayName) deferred to client")
            return nil
        }
    }

    private func handleToolError(
        _ error: Error,
        call: ParsedToolCall,
        toolRef: ToolReference,
        timelineId: UUID,
        continuation: AsyncThrowingStream<ChatEvent, Error>.Continuation
    ) async throws -> ChatQuery.ChatCompletionMessageParam {
        let toolDisplayName = ANSIColors.colorize(call.name, color: ANSIColors.brightCyan)
        let errorMsg = ErrorKit.userFriendlyMessage(for: error)
        logger.error("Tool \(toolDisplayName) error: \(error.localizedDescription)")
        let errorOutput = "Error: \(errorMsg)"
        continuation.yield(.toolCompleted(
            toolCallId: call.callId,
            status: .failed(reference: toolRef, error: error.localizedDescription)
        ))
        try await messageStore.saveMessage(
            ConversationMessage(timelineId: timelineId, role: .tool, content: errorOutput, toolCallId: call.callId)
        )
        return .tool(.init(content: .textContent(.init(errorOutput)), toolCallId: call.callId))
    }

    // MARK: - Core Routing

    /// Routes a single tool call to local or remote execution.
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

        switch workspace.hostType {
        case .server, .serverTimeline:
            let output = try await executeLocally(
                tool: tool,
                arguments: forwardedArguments,
                timelineId: timelineId,
                availableTools: availableTools
            )
            return .completed(output)

        case .client:
            guard !(await timelineManager.getTimeline(id: timelineId)?.isPrivate ?? false) else {
                throw ToolError.clientToolsDisallowedOnPrivateTimeline
            }
            return .deferredToClient
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
           let explicitId = UUID(uuidString: explicitIdString.trimmingCharacters(in: .whitespacesAndNewlines))
        {
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
