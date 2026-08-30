import ErrorKit
import Foundation
import Logging
import PKContracts
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
/// the turn loop and is not part of the downstream public surface.
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
/// Runtime-internal (`package`-scoped); returned by `handlePendingToolCalls` to the turn loop.
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
/// Runtime-internal (`package`-scoped); consumed by the turn loop.
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
/// async handling. `TurnEngine` calls this after each LLM turn that produces tool calls.
actor ToolRouter {
    private let logger: Logger
    private let loggingConfiguration: LoggingConfiguration

    private let threadManager: ThreadManager
    private let workspaceDispatcher: WorkspaceToolDispatcher
    private let runtimeRepository: any ThreadRuntimeRepository
    private let toolExecutionTimeout: TimeInterval
    private let approvalPolicy: any ToolApprovalPolicy
    private let sleep: @Sendable (UInt64) async throws -> Void

    init(
        threadManager: ThreadManager,
        runtimeRepository: any ThreadRuntimeRepository,
        toolExecutionTimeout: TimeInterval = 60,
        approvalPolicy: any ToolApprovalPolicy = DenyAllToolApprovalPolicy(),
        sleep: (@Sendable (UInt64) async throws -> Void)? = nil,
        loggingConfiguration: LoggingConfiguration = .default
    ) {
        self.threadManager = threadManager
        workspaceDispatcher = WorkspaceToolDispatcher(threadManager: threadManager)
        self.runtimeRepository = runtimeRepository
        self.toolExecutionTimeout = toolExecutionTimeout
        self.approvalPolicy = approvalPolicy
        self.sleep = sleep ?? ToolTimeoutEnforcer.defaultSleep
        self.loggingConfiguration = loggingConfiguration
        logger = loggingConfiguration.logger(named: "tool-router")
    }

    // MARK: - Turn-Level API

    /// Processes tool calls from a completed LLM turn.
    ///
    /// Extracts streamed tool call accumulators from `TurnOutputs`, constructs the assistant
    /// message (with tool call definitions for thread history), executes runtime-managed tools,
    /// and returns a decision for the turn loop.
    func processToolCalls(
        outputs: TurnOutputs,
        threadId: UUID,
        turnID: UUID? = nil,
        modelRoundIndex: Int = 0,
        availableTools: [AnyTool],
        workspaceToolCatalog: WorkspaceToolCatalog? = nil,
        continuation: AsyncThrowingStream<TurnEvent, Error>.Continuation
    ) async throws -> ToolTurnResult {
        let accumulators = await outputs.toolCallAccumulators
        guard !accumulators.isEmpty else { return .noToolCalls }

        let sortedCalls = accumulators.sorted(by: { $0.key < $1.key })

        // Parse into routable tool calls
        let parsedCalls = sortedCalls.map { _, value in
            ParsedToolCall(callId: value.callId, name: value.name, argumentsJSON: value.args)
        }

        // Build the assistant message with tool_calls for thread history
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
            threadId: threadId,
            turnID: turnID,
            modelRoundIndex: modelRoundIndex,
            calls: parsedCalls,
            availableTools: availableTools,
            workspaceToolCatalog: workspaceToolCatalog,
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
    /// - Private threads may not defer to externally hosted tools — an error is thrown instead.
    package func handlePendingToolCalls(
        threadId: UUID,
        turnID: UUID? = nil,
        modelRoundIndex: Int = 0,
        calls: [ParsedToolCall],
        availableTools: [AnyTool],
        workspaceToolCatalog: WorkspaceToolCatalog? = nil,
        continuation: AsyncThrowingStream<TurnEvent, Error>.Continuation
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

            var workspaceRoute: WorkspaceToolRoute?
            var effectiveToolRef = toolRef
            var intentRecorded = false

            do {
                let outcome: ToolExecutionOutcome
                if call.name == WorkspaceToolDispatcher.callName {
                    guard let workspaceToolCatalog, !workspaceToolCatalog.isEmpty else {
                        throw ToolError.toolNotFound(call.name)
                    }
                    let dispatch = try workspaceDispatcher.prepare(
                        call: call,
                        catalog: workspaceToolCatalog
                    )
                    workspaceRoute = dispatch.route
                    effectiveToolRef = dispatch.route.tool.toolReference
                    if let turnID {
                        try await runtimeRepository.recordToolIntent(RuntimeToolIntent(
                            turnID: turnID,
                            threadID: threadId,
                            toolCallID: call.callId,
                            name: call.name,
                            arguments: call.argumentsJSON,
                            modelRoundIndex: modelRoundIndex,
                            workspaceID: dispatch.route.workspaceID,
                            workspaceRouting: dispatch.route.routing
                        ))
                        intentRecorded = true
                    }
                    outcome = try await workspaceDispatcher.execute(
                        dispatch,
                        threadID: threadId,
                        using: { [self] tool, arguments in
                            try await executeLocally(
                                tool: tool.toolReference,
                                arguments: arguments,
                                threadId: threadId,
                                dynamicTools: [tool]
                            )
                        }
                    )
                } else {
                    if let turnID {
                        try await runtimeRepository.recordToolIntent(RuntimeToolIntent(
                            turnID: turnID,
                            threadID: threadId,
                            toolCallID: call.callId,
                            name: call.name,
                            arguments: call.argumentsJSON,
                            modelRoundIndex: modelRoundIndex
                        ))
                        intentRecorded = true
                    }
                    guard let arguments = call.arguments else {
                        throw ToolError.malformedArguments("invalid JSON object")
                    }
                    outcome = try await execute(
                        tool: toolRef, arguments: arguments,
                        threadID: threadId, availableTools: availableTools
                    )
                }
                let projection = try await projectOutcome(
                    outcome,
                    call: call,
                    toolRef: effectiveToolRef,
                    workspaceRoute: workspaceRoute,
                    threadId: threadId,
                    turnID: turnID,
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
                // Resolution can fail before the normal intent write (for example, an
                // ambiguous dispatcher call). Persist a route-neutral intent before projecting
                // the model-visible error so the error itself cannot be mistaken for an
                // undurable tool result.
                if !intentRecorded, let turnID {
                    do {
                        try await runtimeRepository.recordToolIntent(RuntimeToolIntent(
                            turnID: turnID,
                            threadID: threadId,
                            toolCallID: call.callId,
                            name: call.name,
                            arguments: call.argumentsJSON,
                            modelRoundIndex: modelRoundIndex
                        ))
                        intentRecorded = true
                    } catch {
                        logger.error(
                            "Unable to persist failed tool intent",
                            metadata: LoggingMetadata.makeMetadata(
                                for: error,
                                correlationID: call.callId
                            )
                        )
                    }
                }
                if let ambiguity = error as? ToolError,
                   case .ambiguousWorkspaceTool = ambiguity,
                   let turnID
                {
                    let correction = ambiguity.userFriendlyMessage
                        + "\n"
                        + (ambiguity.remediation ?? "")
                    do {
                        try await runtimeRepository.appendNotice(
                            turnID: turnID,
                            notice: TurnNotice(
                                kind: "ambiguousWorkspaceTool",
                                message: correction
                            )
                        )
                    } catch {
                        // The model-visible error remains useful even when a host repository
                        // cannot append its audit notice; the following result projection still
                        // preserves the ordinary persistence-failure barrier.
                        logger.error(
                            "Unable to append workspace ambiguity notice",
                            metadata: LoggingMetadata.makeMetadata(
                                for: error,
                                correlationID: call.callId
                            )
                        )
                    }
                }
                let projection = try await projectError(
                    error,
                    call: call,
                    toolRef: effectiveToolRef,
                    workspaceRoute: workspaceRoute,
                    threadId: threadId,
                    turnID: turnID,
                    continuation: continuation
                )
                if projection.persistenceFailed {
                    hasPersistenceFailure = true
                }
                if let message = projection.message { resolvedToolParams.append(message) }
            }
        }

        // modelRoundIndex intentionally omitted: handlePendingToolCalls receives no model-round index, and
        // adding a parameter just for logging exceeds this ticket's blast radius.
        let batchMeta: Logger.Metadata = [
            LogKeys.threadID: .string(threadId.uuidString),
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
    func execute(
        tool: ToolReference,
        arguments: [String: AnyCodable],
        threadID: UUID,
        availableTools: [AnyTool]
    ) async throws -> ToolExecutionOutcome {
        let toolName = loggingConfiguration.redactionPolicy.sanitizeStructured(tool.displayName)
        let sid = threadID.uuidString.prefix(8).lowercased()

        logger.info("Routing \(toolName) in thread \(sid)", metadata: [
            LogKeys.threadID: .string(threadID.uuidString),
            LogKeys.toolName: .string(tool.displayName),
        ])

        // A direct provider call can execute only a runtime/request-scoped tool that preparation
        // exposed by name. Workspace tools remain behind the captured call_tool dispatcher.
        guard let directTool = availableTools.first(where: {
            $0.toolReference == tool || $0.callName == tool.toolID
        })
        else {
            throw ToolError.toolNotFound(tool.displayName)
        }
        let output = try await workspaceDispatcher.executeDirect(
            tool: directTool,
            arguments: arguments,
            using: { [self] directTool, directArguments in
                try await executeLocally(
                    tool: directTool.toolReference,
                    arguments: directArguments,
                    threadId: threadID,
                    dynamicTools: availableTools
                )
            }
        )
        return .completed(output)
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

    // MARK: - Local Execution

    /// Resolves and executes a tool locally: tool-manager lookup, dynamic-tool priority merge,
    /// approval-gate check, and wall-clock timeout enforcement via `ToolTimeoutEnforcer`.
    private func executeLocally(
        tool: ToolReference,
        arguments: [String: AnyCodable],
        threadId: UUID,
        dynamicTools: [AnyTool]?
    ) async throws -> String {
        let toolName = loggingConfiguration.redactionPolicy.sanitizeStructured(tool.displayName)
        logger.info("Executing locally: \(toolName)")

        guard let toolManager = await threadManager.getToolManager(for: threadId) else {
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
        if resolvedTool.requiresPermission(for: arguments) {
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
            logger.error("Failed: \(toolName)", metadata: LoggingMetadata.makeMetadata(for: ToolError.executionFailed(errorMsg), correlationID: threadId.uuidString))
            throw ToolError.executionFailed(errorMsg)
        }
    }

    // MARK: - Tool Turn Projection

    /// Yields the `.attempting` tool-progress event that precedes the execution attempt.
    private func projectAttempt(
        call: ParsedToolCall,
        toolRef: ToolReference,
        continuation: AsyncThrowingStream<TurnEvent, Error>.Continuation
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
        workspaceRoute: WorkspaceToolRoute?,
        threadId: UUID,
        turnID: UUID?,
        continuation: AsyncThrowingStream<TurnEvent, Error>.Continuation
    ) async throws -> ToolProjection {
        let toolDisplayName = loggingConfiguration.redactionPolicy.sanitizeStructured(call.name)
        switch outcome {
        case let .completed(output):
            logger.info("Tool \(toolDisplayName) succeeded")
            let message = ThreadMessage(
                threadID: threadId, role: .tool, content: output, toolCallID: call.callId
            )
            do {
                if let turnID {
                    try await runtimeRepository.recordToolResult(RuntimeToolResult(
                        turnID: turnID,
                        threadID: threadId,
                        toolCallID: call.callId,
                        output: output,
                        workspaceID: workspaceRoute?.workspaceID,
                        workspaceRouting: workspaceRoute?.routing
                    ), message: message)
                } else {
                    try await runtimeRepository.saveMessage(message)
                }
                continuation.yield(.toolCompleted(
                    toolCallID: call.callId,
                    status: .success(ToolResult.success(
                        output,
                        workspaceID: workspaceRoute?.workspaceID,
                        workspaceRouting: workspaceRoute?.routing
                    ))
                ))
            } catch {
                logger.error("Tool persistence failed", metadata: LoggingMetadata.makeMetadata(for: error, correlationID: call.callId))
                continuation.yield(.toolCompleted(
                    toolCallID: call.callId,
                    status: workspaceRoute.map {
                        .workspacePersistenceFailed(
                            reference: toolRef,
                            error: safeErrorMessage(error),
                            workspaceID: $0.workspaceID,
                            routing: $0.routing
                        )
                    } ?? .persistenceFailed(reference: toolRef, error: safeErrorMessage(error))
                ))
                return ToolProjection(
                    message: nil,
                    persistenceFailed: true
                )
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
        workspaceRoute: WorkspaceToolRoute?,
        threadId: UUID,
        turnID: UUID?,
        continuation: AsyncThrowingStream<TurnEvent, Error>.Continuation
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
        let message = ThreadMessage(
            threadID: threadId, role: .tool, content: errorOutput, toolCallID: call.callId
        )
        do {
            if let turnID {
                try await runtimeRepository.recordToolResult(RuntimeToolResult(
                    turnID: turnID,
                    threadID: threadId,
                    toolCallID: call.callId,
                    output: errorOutput,
                    succeeded: false,
                    errorMessage: errorMsg,
                    workspaceID: workspaceRoute?.workspaceID,
                    workspaceRouting: workspaceRoute?.routing
                ), message: message)
            } else {
                try await runtimeRepository.saveMessage(message)
            }
            continuation.yield(.toolCompleted(
                toolCallID: call.callId,
                status: workspaceRoute.map {
                    .workspaceFailed(
                        reference: toolRef,
                        error: safeErrorMessage(error),
                        workspaceID: $0.workspaceID,
                        routing: $0.routing
                    )
                } ?? .failed(reference: toolRef, error: safeErrorMessage(error))
            ))
        } catch {
            logger.error("Tool error persistence failed", metadata: LoggingMetadata.makeMetadata(for: error, correlationID: call.callId))
            continuation.yield(.toolCompleted(
                toolCallID: call.callId,
                status: workspaceRoute.map {
                    .workspacePersistenceFailed(
                        reference: toolRef,
                        error: safeErrorMessage(error),
                        workspaceID: $0.workspaceID,
                        routing: $0.routing
                    )
                } ?? .persistenceFailed(reference: toolRef, error: safeErrorMessage(error))
            ))
            return ToolProjection(
                message: nil,
                persistenceFailed: true
            )
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
    guard let identity = TurnEvent.ErrorIdentity.extracting(from: error) else {
        return "The tool execution failed."
    }
    return "Tool execution failed (\(identity.domain):\(identity.code))."
}
