import ErrorKit
import Foundation
import PKContracts

public enum ToolExecutionStatus: Sendable, Codable {
    case attempting(name: String, reference: ToolReference)
    case success(ToolResult)
    /// A Workspace tool succeeded; the runtime route stays with the execution status.
    case workspaceSucceeded(
        result: ToolResult,
        workspaceID: UUID?,
        routing: WorkspaceToolRouting?
    )
    case failed(reference: ToolReference, error: String)
    /// A resolved Workspace tool failed; provenance remains attached to the failure event.
    case workspaceFailed(
        reference: ToolReference,
        error: String,
        workspaceID: UUID,
        routing: WorkspaceToolRouting
    )
    /// PKTool execution failed before a tool reference was resolved.
    case executionError(String)
    /// The tool executed, but the result could not be persisted to the message store.
    case persistenceFailed(reference: ToolReference, error: String)
    /// A resolved Workspace tool result could not be persisted; provenance remains attached.
    case workspacePersistenceFailed(
        reference: ToolReference,
        error: String,
        workspaceID: UUID,
        routing: WorkspaceToolRouting
    )

    private enum CodingKeys: String, CodingKey {
        case attempting, success, failed, workspaceFailed, executionError
        case persistenceFailed, workspacePersistenceFailed
    }

    private enum ValueCodingKeys: String, CodingKey {
        case value = "_0"
    }

    private enum AttemptingCodingKeys: String, CodingKey {
        case name, reference
    }

    private enum FailureCodingKeys: String, CodingKey {
        case reference, error
    }

    private enum WorkspaceFailureCodingKeys: String, CodingKey {
        case reference, error, workspaceID, routing
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard container.allKeys.count == 1, let key = container.allKeys.first else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Tool execution status must contain exactly one case."
            ))
        }

        switch key {
        case .attempting:
            let payload = try container.nestedContainer(keyedBy: AttemptingCodingKeys.self, forKey: .attempting)
            self = .attempting(
                name: try payload.decode(String.self, forKey: .name),
                reference: try payload.decode(ToolReference.self, forKey: .reference)
            )
        case .success:
            let payload = try container.nestedContainer(keyedBy: ValueCodingKeys.self, forKey: .success)
            let value = try payload.decode(ToolResultWireValue.self, forKey: .value)
            if value.workspaceID != nil || value.workspaceRouting != nil {
                self = .workspaceSucceeded(
                    result: value.toolResult,
                    workspaceID: value.workspaceID,
                    routing: value.workspaceRouting
                )
            } else {
                self = .success(value.toolResult)
            }
        case .failed:
            let payload = try container.nestedContainer(keyedBy: FailureCodingKeys.self, forKey: .failed)
            self = .failed(
                reference: try payload.decode(ToolReference.self, forKey: .reference),
                error: try payload.decode(String.self, forKey: .error)
            )
        case .workspaceFailed:
            let payload = try container.nestedContainer(keyedBy: WorkspaceFailureCodingKeys.self, forKey: .workspaceFailed)
            self = .workspaceFailed(
                reference: try payload.decode(ToolReference.self, forKey: .reference),
                error: try payload.decode(String.self, forKey: .error),
                workspaceID: try payload.decode(UUID.self, forKey: .workspaceID),
                routing: try payload.decode(WorkspaceToolRouting.self, forKey: .routing)
            )
        case .executionError:
            let payload = try container.nestedContainer(keyedBy: ValueCodingKeys.self, forKey: .executionError)
            self = .executionError(try payload.decode(String.self, forKey: .value))
        case .persistenceFailed:
            let payload = try container.nestedContainer(keyedBy: FailureCodingKeys.self, forKey: .persistenceFailed)
            self = .persistenceFailed(
                reference: try payload.decode(ToolReference.self, forKey: .reference),
                error: try payload.decode(String.self, forKey: .error)
            )
        case .workspacePersistenceFailed:
            let payload = try container.nestedContainer(
                keyedBy: WorkspaceFailureCodingKeys.self,
                forKey: .workspacePersistenceFailed
            )
            self = .workspacePersistenceFailed(
                reference: try payload.decode(ToolReference.self, forKey: .reference),
                error: try payload.decode(String.self, forKey: .error),
                workspaceID: try payload.decode(UUID.self, forKey: .workspaceID),
                routing: try payload.decode(WorkspaceToolRouting.self, forKey: .routing)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .attempting(name, reference):
            var payload = container.nestedContainer(keyedBy: AttemptingCodingKeys.self, forKey: .attempting)
            try payload.encode(name, forKey: .name)
            try payload.encode(reference, forKey: .reference)
        case let .success(result):
            try Self.encodeSuccess(result, workspaceID: nil, routing: nil, forKey: .success, in: &container)
        case let .workspaceSucceeded(result, workspaceID, routing):
            try Self.encodeSuccess(
                result,
                workspaceID: workspaceID,
                routing: routing,
                forKey: .success,
                in: &container
            )
        case let .failed(reference, error):
            var payload = container.nestedContainer(keyedBy: FailureCodingKeys.self, forKey: .failed)
            try payload.encode(reference, forKey: .reference)
            try payload.encode(error, forKey: .error)
        case let .workspaceFailed(reference, error, workspaceID, routing):
            var payload = container.nestedContainer(keyedBy: WorkspaceFailureCodingKeys.self, forKey: .workspaceFailed)
            try payload.encode(reference, forKey: .reference)
            try payload.encode(error, forKey: .error)
            try payload.encode(workspaceID, forKey: .workspaceID)
            try payload.encode(routing, forKey: .routing)
        case let .executionError(error):
            var payload = container.nestedContainer(keyedBy: ValueCodingKeys.self, forKey: .executionError)
            try payload.encode(error, forKey: .value)
        case let .persistenceFailed(reference, error):
            var payload = container.nestedContainer(keyedBy: FailureCodingKeys.self, forKey: .persistenceFailed)
            try payload.encode(reference, forKey: .reference)
            try payload.encode(error, forKey: .error)
        case let .workspacePersistenceFailed(reference, error, workspaceID, routing):
            var payload = container.nestedContainer(
                keyedBy: WorkspaceFailureCodingKeys.self,
                forKey: .workspacePersistenceFailed
            )
            try payload.encode(reference, forKey: .reference)
            try payload.encode(error, forKey: .error)
            try payload.encode(workspaceID, forKey: .workspaceID)
            try payload.encode(routing, forKey: .routing)
        }
    }

    private static func encodeSuccess(
        _ result: ToolResult,
        workspaceID: UUID?,
        routing: WorkspaceToolRouting?,
        forKey key: CodingKeys,
        in container: inout KeyedEncodingContainer<CodingKeys>
    ) throws {
        var payload = container.nestedContainer(keyedBy: ValueCodingKeys.self, forKey: key)
        try payload.encode(
            ToolResultWireValue(result: result, workspaceID: workspaceID, workspaceRouting: routing),
            forKey: .value
        )
    }
}

private struct ToolResultWireValue: Codable {
    let isSuccess: Bool
    let output: String
    let error: String?
    let workspaceID: UUID?
    let workspaceRouting: WorkspaceToolRouting?

    init(result: ToolResult, workspaceID: UUID?, workspaceRouting: WorkspaceToolRouting?) {
        isSuccess = result.isSuccess
        output = result.output
        error = result.error
        self.workspaceID = workspaceID
        self.workspaceRouting = workspaceRouting
    }

    var toolResult: ToolResult {
        ToolResult(isSuccess: isSuccess, output: output, error: error)
    }
}

/// Events emitted by TurnEngine during a turn.
///
/// Events are categorized into three groups:
/// - `delta`: Incremental streaming events (text, reasoning, tool calls, tool progress)
/// - `error`: Error events (tool errors, general errors)
/// - `completion`: Terminal events signaling final results
public enum TurnEvent: Sendable, Codable {
    /// The shared structured identity of a PKError reported by this Turn.
    public typealias ErrorIdentity = PKContracts.ErrorIdentity

    public enum DeltaEvent: Sendable, Codable {
        /// Chain-of-thought reasoning chunk
        case reasoning(text: String)
        /// Incremental content chunk from the LLM
        case generation(text: String)
        /// Incremental decoded audio output.
        case audio(delta: LLMAudioDelta)
        /// PKTool call being assembled (streaming deltas)
        case toolCall(delta: ToolCallDelta)

        /// Asynchronous tool execution status update (progress)
        case toolExecution(toolCallID: String, status: ToolExecutionStatus)

        /// Sidecar directive field update (piggy-backed structured output)
        case sidecar(delta: SidecarDelta)

        // Coding is synthesized; this only maps the `toolCallID` label to its wire key.
        private enum ToolExecutionCodingKeys: String, CodingKey {
            case toolCallID = "toolCallId"
            case status
        }
    }

    public enum ErrorEvent: Sendable, Codable {
        /// PKTool call failed before execution (e.g. not found, invalid arguments)
        case toolCallError(toolCallID: String, name: String, error: String)
        /// General error occurred.
        ///
        /// `identity` carries an optional structured error identity (`errorDomain` +
        /// `errorCode`) extracted from a `PKError` when the event was produced from a
        /// thrown error (STAB-6). Consumers classify turn state by switching on
        /// `identity` rather than sniffing `message` substrings: a bare-string
        /// `.error` event (or any non-`PKError` error) yields `identity == nil`, in
        /// which case the turn is classified as a plain failure rather than blocked.
        case error(message: String, identity: ErrorIdentity?)
        /// The terminal outcome could not be persisted, so the Turn has no durable outcome.
        ///
        /// This is intentionally distinct from ``error(message:identity:)``: consumers can
        /// retry or surface a durability problem without treating it as a provider failure.
        case durabilityFailure(message: String, identity: ErrorIdentity?)
        /// Generation was explicitly cancelled
        case generationCancelled

        // Coding is synthesized; this only maps the `toolCallID` label to its wire key.
        private enum ToolCallErrorCodingKeys: String, CodingKey {
            case toolCallID = "toolCallId"
            case name, error
        }
    }

    public enum CompletionEvent: Sendable, Codable {
        /// Stream completed with final accumulated message and token metadata
        case generationCompleted(message: Message, metadata: LLMResponse)
        /// The provider finished successfully, but the reconstructed assistant text was empty.
        case completedEmpty(finishReason: String?)
        /// PKTool execution completed with final status
        case toolExecution(toolCallID: String, status: ToolExecutionStatus)
        /// The ReAct loop exhausted its `maxModelRounds` budget while tool calls were still pending,
        /// so the agent never produced a tool-free final response. Terminal: emitted exactly
        /// once before the stream closes, in place of `.generationCompleted`, so consumers can
        /// distinguish model-round exhaustion from normal completion (PKRR-011).
        case maxModelRoundsReached
        /// The turn ended because at least one tool call was deferred for external (host-side)
        /// execution. Terminal: emitted exactly once before the stream closes, in place of
        /// `.generationCompleted`, so consumers can distinguish deferred external tool work
        /// from normal completion (PKRR-011).
        case deferredForExternalTool

        /// All sidecar directives resolved for the turn (values, declines, failures)
        case sidecarsCompleted(SidecarCompletion)

        // Coding is synthesized; this only maps the `toolCallID` label to its wire key.
        private enum ToolExecutionCodingKeys: String, CodingKey {
            case toolCallID = "toolCallId"
            case status
        }
    }

    case delta(DeltaEvent)
    case error(ErrorEvent)
    case completion(CompletionEvent)
    /// A per-model-round prompt-cache diagnostic. Not terminal: it is emitted after each model
    /// round's usage arrives, before the loop decides whether to continue.
    case promptCacheReport(PromptCacheReport)
}

// MARK: - Factory Methods (Producer Ergonomics)

public extension TurnEvent {
    /// Whether this event terminates a Turn stream.
    var isTerminal: Bool {
        switch self {
        case .error:
            return true
        case .promptCacheReport:
            return false
        case let .completion(event):
            switch event {
            case .generationCompleted, .completedEmpty, .maxModelRoundsReached,
                 .deferredForExternalTool:
                return true
            case .toolExecution, .sidecarsCompleted:
                return false
            }
        case .delta:
            return false
        }
    }

    // MARK: - Delta Shortcuts

    /// Creates a reasoning delta event containing a streamed reasoning fragment.
    static func reasoning(_ text: String) -> TurnEvent {
        .delta(.reasoning(text: text))
    }

    /// Creates a generation delta event containing a streamed assistant-content fragment.
    static func generation(_ text: String) -> TurnEvent {
        .delta(.generation(text: text))
    }

    /// Creates an audio delta event containing decoded audio output.
    static func audio(_ delta: LLMAudioDelta) -> TurnEvent {
        .delta(.audio(delta: delta))
    }

    /// Creates a tool-call delta event for an incrementally assembled tool call.
    static func toolCall(_ delta: ToolCallDelta) -> TurnEvent {
        .delta(.toolCall(delta: delta))
    }

    /// Creates a delta event reporting an asynchronous tool execution status update.
    static func toolProgress(toolCallID: String, status: ToolExecutionStatus) -> TurnEvent {
        .delta(.toolExecution(toolCallID: toolCallID, status: status))
    }

    /// Creates a sidecar delta event containing a structured-output directive update.
    static func sidecar(_ delta: SidecarDelta) -> TurnEvent {
        .delta(.sidecar(delta: delta))
    }

    // MARK: - Error Shortcuts

    /// Creates an error event for a tool call that failed before execution.
    static func toolCallError(toolCallID: String, name: String, error: String) -> TurnEvent {
        .error(.toolCallError(toolCallID: toolCallID, name: name, error: error))
    }

    /// Creates an error event from `error`, using ErrorKit's user-facing message
    /// and extracting stable error identity when available.
    static func error(_ error: Error) -> TurnEvent {
        .error(.error(
            message: ErrorKit.userFriendlyMessage(for: error),
            identity: ErrorIdentity.extracting(from: error)
        ))
    }

    /// Creates an error event with `message` and no structured error identity.
    static func error(_ message: String) -> TurnEvent {
        .error(.error(message: message, identity: nil))
    }

    /// Creates a distinct durability-failure event from `error`, using ErrorKit's
    /// user-facing message and extracting stable error identity when available.
    static func durabilityFailure(_ error: Error) -> TurnEvent {
        .error(.durabilityFailure(
            message: ErrorKit.userFriendlyMessage(for: error),
            identity: ErrorIdentity.extracting(from: error)
        ))
    }

    /// Creates an error event indicating that generation was explicitly cancelled.
    static func generationCancelled() -> TurnEvent {
        .error(.generationCancelled)
    }

    // MARK: - Completion Shortcuts

    /// Creates a terminal completion event with the final message and response metadata.
    static func generationCompleted(message: Message, metadata: LLMResponse) -> TurnEvent {
        .completion(.generationCompleted(message: message, metadata: metadata))
    }

    /// Creates a terminal completion event for a successful response with no assistant text.
    static func completedEmpty(finishReason: String?) -> TurnEvent {
        .completion(.completedEmpty(finishReason: finishReason))
    }

    /// Creates a tool-execution completion event that does not terminate the Turn.
    static func toolCompleted(toolCallID: String, status: ToolExecutionStatus) -> TurnEvent {
        .completion(.toolExecution(toolCallID: toolCallID, status: status))
    }

    /// Creates a terminal completion event indicating that the model-round budget
    /// was exhausted before a tool-free response.
    static func maxModelRoundsReached() -> TurnEvent {
        .completion(.maxModelRoundsReached)
    }

    /// Creates a terminal completion event indicating that continuation proceeds through host-side tool execution.
    static func deferredForExternalTool() -> TurnEvent {
        .completion(.deferredForExternalTool)
    }

    /// Creates a non-terminal completion event containing resolved sidecar directive results.
    static func sidecarsCompleted(_ completion: SidecarCompletion) -> TurnEvent {
        .completion(.sidecarsCompleted(completion))
    }
}

// MARK: - Computed Properties (Consumer Ergonomics)

public extension TurnEvent {
    /// The text content if this is a `.delta(.generation(...))` event.
    var textContent: String? {
        if case let .delta(event) = self, case let .generation(text) = event { return text }
        return nil
    }

    /// The reasoning content if this is a `.delta(.reasoning(...))` event.
    var reasoningContent: String? {
        if case let .delta(event) = self, case let .reasoning(text) = event { return text }
        return nil
    }

    /// The decoded audio fragment if this is an audio delta event.
    var audioDelta: LLMAudioDelta? {
        if case let .delta(event) = self, case let .audio(delta) = event { return delta }
        return nil
    }

    /// The completed message and metadata if this is a `.completion(.generationCompleted(...))` event.
    var completedMessage: (message: Message, metadata: LLMResponse)? {
        if case let .completion(event) = self, case let .generationCompleted(msg, meta) = event { return (msg, meta) }
        return nil
    }

    /// The finish reason for an empty but successfully completed assistant response, if present.
    var emptyCompletionFinishReason: String? {
        if case let .completion(event) = self, case let .completedEmpty(finishReason) = event { return finishReason }
        return nil
    }

    /// The prompt-cache diagnostic if this is a `.promptCacheReport(...)` event.
    var promptCacheReport: PromptCacheReport? {
        if case let .promptCacheReport(report) = self { return report }
        return nil
    }

    /// The sidecar delta if this is a `.delta(.sidecar(...))` event.
    var sidecarDelta: SidecarDelta? {
        if case let .delta(event) = self, case let .sidecar(delta) = event { return delta }
        return nil
    }

    /// The sidecar results if this is a `.completion(.sidecarsCompleted(...))` event.
    var sidecarResults: [SidecarResult]? {
        sidecarCompletion?.results
    }

    /// The identified sidecar completion if this is a committed sidecar event.
    var sidecarCompletion: SidecarCompletion? {
        if case let .completion(event) = self, case let .sidecarsCompleted(completion) = event {
            return completion
        }
        return nil
    }
}

// MARK: - Blocked Error Identity Contract (STAB-6)
//
// Blocked-error classification now lives on `PKError.isBlocked` (default `false`,
// overridden `true` on the error cases that represent blocked/approval/disallowed
// conditions). `ErrorIdentity.extracting(from:)` copies `PKError.isBlocked` onto the
// identity's stored `isBlocked` field at extraction time, so consumers classify turn
// state by checking `identity?.isBlocked` without needing a hand-curated `(domain,
// code)` set. Extraction traverses `CausalError` wrappers (e.g. `PipelineError`) to
// find the root `PKError`, so a blocked error wrapped by a pipeline stage retains
// its blocked classification (PKRR-014). The error types that override
// `isBlocked = true`:
// - `ToolError.permissionDenied` — `com.positronickit.core.tool:210`
// - `ToolError.attachedToolsDisallowedOnPrivateTimeline` — `com.positronickit.core.tool:207`
// - `PathSanitizer.PathError.accessDenied` — `com.positronickit.core.filesystem:101`
// - `WorkspaceError.accessDenied` — `com.positronickit.core.workspace:3002`
