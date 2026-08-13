import ErrorKit
import Foundation
import Logging
import PKShared
import PKUtilities

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
    /// Whether a runtime tool result could not be persisted.
    package let hasPersistenceFailure: Bool
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
    /// A tool result could not be persisted. The pending assistant call remains retryable, so the
    /// loop must stop before sending an undurable result to the provider.
    case persistenceFailed
    /// At least one tool call was deferred for external execution — stop and wait.
    case deferredExternally
}

// MARK: - ToolRouter

/// Routes tool execution requests to the appropriate handler (local or externally hosted).
///
/// The primary entry point is `handlePendingToolCalls()`, which executes runtime-managed tools
/// immediately (persisting results to the message store) and defers externally hosted tools for
/// async handling. `ChatEngine` calls this after each LLM turn that produces tool calls.
public actor ToolRouter {
    private let logger: Logger
    private let loggingConfiguration: LoggingConfiguration

    private let threadManager: ThreadManager
    private let messageStore: any MessageStoreProtocol
    private let toolExecutionTimeout: TimeInterval
    private let approvalPolicy: any ToolApprovalPolicy
    private let sleep: @Sendable (UInt64) async throws -> Void

    public init(
        threadManager: ThreadManager,
        messageStore: any MessageStoreProtocol,
        toolExecutionTimeout: TimeInterval = 60,
        approvalPolicy: any ToolApprovalPolicy = DenyAllToolApprovalPolicy(),
        sleep: (@Sendable (UInt64) async throws -> Void)? = nil
        , loggingConfiguration: LoggingConfiguration = .default
    ) {
        self.threadManager = threadManager
        self.messageStore = messageStore
        self.toolExecutionTimeout = toolExecutionTimeout
        self.approvalPolicy = approvalPolicy
        self.sleep = sleep ?? ToolTimeoutEnforcer.defaultSleep
        self.loggingConfiguration = loggingConfiguration
        self.logger = loggingConfiguration.logger(named: "tool-router")
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
        let audioData = await outputs.audioData
        let audioFormat = await outputs.audioFormat
        let audioTranscript = await outputs.audioTranscript
        let audioContinuation = await outputs.audioContinuation
        var contentParts: [MessageContentPart] = []
        if !fullResponse.isEmpty { contentParts.append(.text(fullResponse)) }
        if !audioData.isEmpty, let audioFormat {
            contentParts.append(.audio(AudioContent(
                data: audioData,
                format: audioFormat,
                transcript: audioTranscript.isEmpty ? nil : audioTranscript,
                continuation: audioContinuation
            )))
        }
        let assistantParam = LLMMessage(
            role: .assistant,
            content: MessageContent(parts: contentParts),
            toolCalls: toolCallsParam
        )

        // Route and execute
        let result = try await handlePendingToolCalls(
            timelineId: timelineId,
            calls: parsedCalls,
            availableTools: availableTools,
            continuation: continuation
        )

        if result.hasPersistenceFailure { return .persistenceFailed }
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
        var hasPersistenceFailure = false
        var resolvedToolParams: [LLMMessage] = []
        var deferredCount = 0
        var failedCount = 0
        var deferredCallIDs: [Logger.Metadata.Value] = []

        for call in calls {
            let toolRef = resolveToolReference(
                for: call,
                availableTools: availableTools
            )

            projectAttempt(
                call: call,
                toolRef: toolRef,
                continuation: continuation
            )

            do {
                guard let arguments = call.arguments else {
                    throw ToolError.malformedArguments("invalid JSON object")
                }
                let outcome = try await execute(
                    tool: toolRef, arguments: arguments,
                    threadID: timelineId, availableTools: availableTools
                )
                let projection = try await projectOutcome(
                    outcome,
                    call: call,
                    toolRef: toolRef,
                    timelineId: timelineId,
                    continuation: continuation
                )
                if projection.persistenceFailed {
                    hasPersistenceFailure = true
                }
                if let param = projection.message { resolvedToolParams.append(param) }
                if case .deferredExternally = outcome {
                    hasDeferred = true
                    deferredCount += 1
                    deferredCallIDs.append(.string(redactedHash(call.callId)))
                }
            } catch {
                failedCount += 1
                let projection = try await projectError(
                    error,
                    call: call,
                    toolRef: toolRef,
                    timelineId: timelineId,
                    continuation: continuation
                )
                if projection.persistenceFailed {
                    hasPersistenceFailure = true
                }
                if let message = projection.message { resolvedToolParams.append(message) }
            }
        }

        // turnIndex intentionally omitted: handlePendingToolCalls receives no turn count, and
        // adding a parameter just for logging exceeds this ticket's blast radius.
        let batchMeta: Logger.Metadata = [
            LogKeys.timelineID: .string(timelineId.uuidString),
            "total": .string("\(calls.count)"),
            "deferred": .string("\(deferredCount)"),
            "resolved": .string("\(resolvedToolParams.count)"),
            "failed": .string("\(failedCount)"),
            "persistenceFailed": .string(hasPersistenceFailure ? "true" : "false"),
            "deferredCallIDs": .array(deferredCallIDs),
        ]
        logger.debug("Tool batch routed", metadata: batchMeta)

        return ToolHandlingResult(
            hasDeferred: hasDeferred,
            hasPersistenceFailure: hasPersistenceFailure,
            resolvedToolParams: resolvedToolParams
        )
    }

    // MARK: - Core Routing

    /// Routes a single tool call to local or external execution.
    public func execute(
        tool: ToolReference,
        arguments: [String: AnyCodable],
        threadID: UUID,
        availableTools: [AnyTool]? = nil
    ) async throws -> ToolExecutionOutcome {
        let toolName = loggingConfiguration.redactionPolicy.sanitizeStructured(tool.displayName)
        let sid = threadID.uuidString.prefix(8).lowercased()

        logger.info("Routing \(toolName) in thread \(sid)", metadata: [
            LogKeys.timelineID: .string(threadID.uuidString),
            LogKeys.toolName: .string(tool.displayName),
        ])

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
           dynamicTools.contains(where: { $0.toolReference == tool || $0.callName == tool.toolID })
        {
            let output = try await executeLocally(
                tool: tool,
                arguments: forwardedArguments,
                timelineId: threadID,
                dynamicTools: dynamicTools
            )
            return .completed(output)
        }

        // resolveWorkspace returns nil when the tool is not registered in any of the
        // timeline's workspaces, or when the timeline has no workspaces at all.
        guard let workspaceId = try await resolveWorkspace(
            for: tool,
            in: threadID,
            arguments: arguments
        ) else {
            throw ToolError.toolNotFound(tool.displayName)
        }

        guard let workspace = try await threadManager.getWorkspace(workspaceId) else {
            throw ToolError.workspaceNotFound(workspaceId)
        }

        switch try outcomeForWorkspace(
            location: workspace.location,
            timelineIsPrivate: await threadManager.thread(id: threadID)?.isPrivate ?? false
        ) {
        case .executeLocally:
            let output = try await executeLocally(
                tool: tool,
                arguments: forwardedArguments,
                timelineId: threadID,
                dynamicTools: availableTools
            )
            return .completed(output)

        case .deferExternally:
            return .deferredExternally
        }
    }

    // MARK: - Tool Reference Resolution

    /// Selects the effective `ToolReference` for a parsed call: a matching dynamic tool's custom
    /// reference wins over the `.known` fallback.
    private func resolveToolReference(
        for call: ParsedToolCall,
        availableTools: [AnyTool]
    ) -> ToolReference {
        availableTools.first(where: { $0.callName == call.name })?.toolReference
            ?? ToolReference.known(id: call.name)
    }

    // MARK: - Workspace Resolution

    /// Decides whether a resolved workspace location implies runtime-local execution or external
    /// deferral. Private timelines reject externally hosted tools.
    private func outcomeForWorkspace(
        location: WorkspaceReference.WorkspaceLocation,
        timelineIsPrivate: Bool
    ) throws -> WorkspaceExecutionDisposition {
        switch location {
        case .runtime, .runtimeThread, .runtimeTimeline:
            return .executeLocally
        case .attached:
            guard !timelineIsPrivate else {
                throw ToolError.attachedToolsDisallowedOnPrivateThread
            }
            return .deferExternally
        }
    }

    /// Resolves the workspace to execute `tool` against for a given timeline.
    ///
    /// Resolution order:
    /// 1. If the caller supplied an explicit `workspaceID` argument, it must be a string that
    ///    parses as a UUID and match one of the timeline's candidate workspace ids. A malformed
    ///    value throws `ToolError.invalidWorkspaceID`; a valid UUID that is not attached throws
    ///    `ToolError.workspaceNotFound` (PKRR-015 fail-closed — presence signals explicit
    ///    intent, so a malformed value is an error, not a hint to auto-route).
    /// 2. Otherwise, defer to `ThreadManager.findWorkspaceForTool(_:in:)` over the candidate
    ///    list (primary first, then attached in declared order).
    /// 3. Returns `nil` if the timeline has no workspaces, or if no candidate workspace
    ///    registers the tool. `execute` interprets `nil` as `toolNotFound`.
    private func resolveWorkspace(
        for tool: ToolReference,
        in timelineId: UUID,
        arguments: [String: AnyCodable]
    ) async throws -> UUID? {
        let wsList: WorkspaceQueryResult
        do {
            wsList = try await threadManager.getWorkspaces(for: timelineId)
        } catch ThreadError.threadNotFound {
            return nil
        }

        let candidates = ([wsList.primary].compactMap { $0?.id }) + wsList.attached.map { $0.id }

        // Check for explicit intent in arguments. Presence of `workspaceID` signals explicit
        // routing intent: a malformed value is an error, not a hint to fall back to
        // auto-routing (PKRR-015).
        if let explicitAnyCodable = arguments["workspaceID"] {
            let explicitValue = explicitAnyCodable.value
            guard let explicitIdString = explicitValue as? String,
                  let explicitId = UUID(uuidString: explicitIdString.trimmingCharacters(in: .whitespacesAndNewlines))
            else {
                throw ToolError.invalidWorkspaceID(explicitAnyCodable.description)
            }

            guard candidates.contains(explicitId) else {
                throw ToolError.workspaceNotFound(explicitId)
            }

            logger.debug("Routing to explicitly requested workspace: \(explicitId)")
            return explicitId
        }

        return try await threadManager.findWorkspaceForTool(tool, in: candidates)
    }

    // MARK: - Local Execution

    /// Resolves and executes a tool locally: tool-manager lookup, dynamic-tool priority merge,
    /// approval-gate check, and wall-clock timeout enforcement via `ToolTimeoutEnforcer`.
    private func executeLocally(
        tool: ToolReference,
        arguments: [String: AnyCodable],
        timelineId: UUID,
        dynamicTools: [AnyTool]?
    ) async throws -> String {
        let toolName = loggingConfiguration.redactionPolicy.sanitizeStructured(tool.displayName)
        logger.info("Executing locally: \(toolName)")

        guard let toolManager = await threadManager.getToolManager(for: timelineId) else {
            throw ToolError.toolNotFound(tool.displayName)
        }

        var toolList = await toolManager.getAvailableTools()
        if let dynamicTools {
            // Dynamic tools take priority; exclude static tools with the same ID.
            let dynamicIds = Set(dynamicTools.map { $0.callName })
            toolList = dynamicTools + toolList.filter { !dynamicIds.contains($0.callName) }
        }

        guard let resolvedTool = toolList.first(where: {
            $0.toolReference == tool || $0.callName == tool.toolID
        }) else {
            throw ToolError.toolNotFound(tool.displayName)
        }

        // Enabledness is an execution policy, not just prompt state. Check the resolved call
        // name here, after dynamic tools have been merged, so a per-turn tool cannot bypass a
        // disabled registered tool with the same name.
        let disabledToolIDs = await toolManager.disabledToolIDs()
        guard !disabledToolIDs.contains(resolvedTool.callName) else {
            throw ToolError.toolNotFound(tool.displayName)
        }

        // Approval gate: a tool that declares `requiresPermission` must not execute until the
        // injected gate returns `.approve`. This is the single runtime execution sink — both
        // structured provider tool calls and text-fallback `${tool}` calls reach it — so the
        // approval contract holds regardless of how the call was produced (YAK-31). Non-permissioned
        // tools skip the gate entirely.
        if resolvedTool.requiresPermission {
            let decision = await approvalPolicy.requestApproval(tool: resolvedTool, arguments: arguments)
            guard decision == .approve else {
                logger.warning("Permission denied for \(toolName)")
                throw ToolError.permissionDenied(resolvedTool.name)
            }
        }

        let result = try await ToolTimeoutEnforcer.execute(
            resolvedTool,
            arguments: arguments,
            timeout: toolExecutionTimeout,
            sleep: sleep
        )
        if result.success {
            logger.info("Success: \(toolName)")
            return result.output
        } else {
            let errorMsg = result.error ?? "Unknown error"
            logger.error("Failed: \(toolName)", metadata: LoggingMetadata.makeMetadata(for: ToolError.executionFailed(errorMsg), correlationID: timelineId.uuidString))
            throw ToolError.executionFailed(errorMsg)
        }
    }

    // MARK: - Tool Turn Projection

    /// Yields the `.attempting` tool-progress event that precedes the execution attempt.
    private func projectAttempt(
        call: ParsedToolCall,
        toolRef: ToolReference,
        continuation: AsyncThrowingStream<ChatEvent, Error>.Continuation
    ) {
        continuation.yield(.toolProgress(
            toolCallID: call.callId,
            status: .attempting(name: call.name, reference: toolRef)
        ))
    }

    /// Projects a successful or deferred outcome into a persisted tool message, a chat event,
    /// and an optional provider-neutral follow-up message.
    ///
    /// The tool result is persisted **before** the terminal `.success` event is emitted, so
    /// a consumer that observes `.success` is guaranteed the result is durable. If persistence
    /// fails, `.persistenceFailed` is emitted instead — never `.success` (PKRR-016).
    private func projectOutcome(
        _ outcome: ToolExecutionOutcome,
        call: ParsedToolCall,
        toolRef: ToolReference,
        timelineId: UUID,
        continuation: AsyncThrowingStream<ChatEvent, Error>.Continuation
    ) async throws -> ToolProjection {
        let toolDisplayName = loggingConfiguration.redactionPolicy.sanitizeStructured(call.name)
        switch outcome {
        case let .completed(output):
            logger.info("Tool \(toolDisplayName) succeeded")
            let message = ConversationMessage(
                threadID: timelineId, role: .tool, content: output, toolCallID: call.callId
            )
            do {
                try await messageStore.saveMessage(message)
                continuation.yield(.toolCompleted(
                    toolCallID: call.callId, status: .success(ToolResult.success(output))
                ))
            } catch {
                logger.error("Tool persistence failed", metadata: LoggingMetadata.makeMetadata(for: error, correlationID: call.callId))
                continuation.yield(.toolCompleted(
                    toolCallID: call.callId,
                    status: .persistenceFailed(reference: toolRef, error: safeErrorMessage(error))
                ))
                return ToolProjection(message: nil, persistenceFailed: true)
            }
            return ToolProjection(
                message: LLMMessage(role: .tool, content: output, toolCallID: call.callId),
                persistenceFailed: false
            )

        case .deferredExternally:
            logger.info("Tool \(toolDisplayName) deferred for external execution")
            return ToolProjection(message: nil, persistenceFailed: false)
        }
    }

    /// Projects an execution error into a persisted error message (with remediation guidance),
    /// a failed chat event, and a provider-neutral follow-up message.
    ///
    /// The error message is persisted **before** the terminal `.failed` event is emitted, so
    /// a consumer that observes `.failed` is guaranteed the error is durable. If persistence
    /// fails, `.persistenceFailed` is emitted instead — never `.failed` (PKRR-016).
    private func projectError(
        _ error: Error,
        call: ParsedToolCall,
        toolRef: ToolReference,
        timelineId: UUID,
        continuation: AsyncThrowingStream<ChatEvent, Error>.Continuation
    ) async throws -> ToolProjection {
        let errorMsg = ErrorKit.userFriendlyMessage(for: error)
        logger.error("Tool execution failed", metadata: LoggingMetadata.makeMetadata(for: error, correlationID: call.callId))
        // Surface the error's built-in remediation (a second-person "how to fix it" hint, often
        // with a worked example) back to the model so a failed tool call guides recovery rather
        // than dead-ending. Kept out of the steady-state prompt to stay lean — the model only
        // pays for this guidance on the turn it actually errors.
        var errorOutput = "Error: \(errorMsg)"
        if let remediation = (error as? any PKError)?.remediation, !remediation.isEmpty {
            errorOutput += "\nHow to fix: \(remediation)"
        }
        let message = ConversationMessage(
            threadID: timelineId, role: .tool, content: errorOutput, toolCallID: call.callId
        )
        do {
            try await messageStore.saveMessage(message)
            continuation.yield(.toolCompleted(
                toolCallID: call.callId,
                 status: .failed(reference: toolRef, error: safeErrorMessage(error))
            ))
        } catch {
            logger.error("Tool error persistence failed", metadata: LoggingMetadata.makeMetadata(for: error, correlationID: call.callId))
            continuation.yield(.toolCompleted(
                toolCallID: call.callId,
                status: .persistenceFailed(reference: toolRef, error: safeErrorMessage(error))
            ))
            return ToolProjection(message: nil, persistenceFailed: true)
        }
        return ToolProjection(
            message: LLMMessage(role: .tool, content: errorOutput, toolCallID: call.callId),
            persistenceFailed: false
        )
    }
}

private struct ToolProjection {
    let message: LLMMessage?
    let persistenceFailed: Bool
}

private func safeErrorMessage(_ error: Error) -> String {
    guard let identity = ChatEvent.ErrorIdentity.extracting(from: error) else {
        return "The tool execution failed."
    }
    return "Tool execution failed (\(identity.domain):\(identity.code))."
}

// MARK: - Workspace Execution Disposition

/// Whether a resolved workspace should execute its tool locally or defer to an external host.
private enum WorkspaceExecutionDisposition {
    case executeLocally
    case deferExternally
}
