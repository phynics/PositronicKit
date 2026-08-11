import ErrorKit
import Foundation

public enum ToolExecutionStatus: Sendable, Codable {
    case attempting(name: String, reference: ToolReference)
    case success(ToolResult)
    case failed(reference: ToolReference, error: String)
    /// Tool execution failed without a tool reference (e.g. the tool could not be
    /// resolved before execution began). Distinct from `.failed` which carries the
    /// `ToolReference` of the tool that was attempted, and from `ToolResult.failure(_:)`
    /// which is the static factory that constructs a failed `ToolResult` value (a
    /// result, not a lifecycle status).
    case executionError(String)
    /// The tool executed (successfully or with an error) but the result could not be
    /// persisted to the message store. Emitted instead of `.success` or `.failed` when
    /// `saveMessage` throws, so the terminal status is always consistent with persisted
    /// history — a consumer that observes `.persistenceFailed` knows the result is not
    /// durable and a retry may be needed (PKRR-016).
    case persistenceFailed(reference: ToolReference, error: String)
}

/// Events emitted by ChatEngine during a chat turn.
///
/// Events are categorized into four groups:
/// - `delta`: Incremental streaming events (text, reasoning, tool calls, tool progress)
/// - `meta`: Informational metadata events (context, generation info)
/// - `error`: Error events (tool errors, general errors)
/// - `completion`: Terminal events signaling final results
public enum ChatEvent: Sendable, Codable {
    /// A value-type projection of a `PKError`'s stable identity (`errorDomain` +
    /// `errorCode`), carried on `.error` events so consumers can classify turn
    /// failures by structured error identity instead of sniffing message substrings
    /// (STAB-6).
    ///
    /// It is a plain value type (`String` + `Int`) so `ChatEvent` stays `Sendable`,
    /// `Equatable`, and `Codable` without carrying an untyped `Error`. Extraction
    /// traverses the causal chain through ``CausalError`` conformers (e.g.
    /// `PipelineError`) to find the root `PKError` identity — so a provider 429
    /// wrapped in a pipeline stage failure retains its LLM/HTTP identity instead of
    /// collapsing to the generic pipeline code 4001 (PKRR-014). Non-`PKError` errors
    /// (including `CancellationError` and foreign provider failures wrapped only by
    /// `PipelineError`) yield `identity == nil` and are intentionally not classified
    /// as blocked (see `blockedIdentityContract`).
    ///
    /// `isBlocked` is carried as a stored field, populated by `extracting(from:)`
    /// from `PKError.isBlocked` at extraction time. This moves the classification
    /// onto the error types themselves rather than a hand-curated `(domain, code)`
    /// set. Directly constructed identities (via `init(domain:code:)`) default
    /// `isBlocked` to `false` since they are not derived from a concrete error.
    public struct ErrorIdentity: Sendable, Equatable, Hashable, Codable {
        /// The error domain identifying the module the error originated in
        /// (a `PKErrorDomain` string, e.g. `"com.positronickit.core.tool"`).
        public let domain: String
        /// A unique integer code for the specific error case within the domain.
        public let code: Int
        /// Whether this identity represents a blocked/approval/disallowed condition,
        /// derived from `PKError.isBlocked` at extraction time. Identities constructed
        /// directly (not via `extracting(from:)`) default to `false`.
        public let isBlocked: Bool

        public init(domain: String, code: Int, isBlocked: Bool = false) {
            self.domain = domain
            self.code = code
            self.isBlocked = isBlocked
        }

        /// Extracts an `ErrorIdentity` from `error` by traversing the causal chain
        /// through ``CausalError`` conformers to find the root `PKError` identity
        /// (PKRR-014).
        ///
        /// When the error is a `CausalError` wrapper (e.g.
        /// `PipelineError.stageFailed`), extraction recurses into the underlying
        /// causes and returns the first `PKError` identity found — preserving the
        /// root cause's domain/code/isBlocked instead of the wrapper's. If no
        /// `PKError` is found in the causal chain, the wrapper's own `PKError`
        /// identity is used as a fallback when `usesOwnIdentityAsFallback` is
        /// `true` (the default), or `nil` when it is `false` (e.g.
        /// `PipelineError`, whose stage-failure code is orchestration context
        /// rather than the root cause).
        ///
        /// Non-`CausalError` errors are inspected directly: if they conform to
        /// `PKError`, their identity is returned; otherwise `nil`. The `isBlocked`
        /// field is populated from `PKError.isBlocked` so blocked-error
        /// classification lives on the error types themselves.
        public static func extracting(from error: Error) -> ErrorIdentity? {
            if let causal = error as? CausalError {
                for cause in causal.underlyingCauses {
                    if let identity = extracting(from: cause) {
                        return identity
                    }
                }
                if causal.usesOwnIdentityAsFallback, let pk = error as? any PKError {
                    return ErrorIdentity(domain: pk.errorDomain, code: pk.errorCode, isBlocked: pk.isBlocked)
                }
                return nil
            }
            if let pk = error as? any PKError {
                return ErrorIdentity(domain: pk.errorDomain, code: pk.errorCode, isBlocked: pk.isBlocked)
            }
            return nil
        }

        // MARK: - Equatable / Hashable (identity is domain + code only; isBlocked is derived)

        public static func == (lhs: ErrorIdentity, rhs: ErrorIdentity) -> Bool {
            lhs.domain == rhs.domain && lhs.code == rhs.code
        }

        public func hash(into hasher: inout Hasher) {
            hasher.combine(domain)
            hasher.combine(code)
        }

        // MARK: - Codable (isBlocked is optional on decode for backward compatibility)

        private enum CodingKeys: String, CodingKey {
            case domain, code, isBlocked
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            domain = try container.decode(String.self, forKey: .domain)
            code = try container.decode(Int.self, forKey: .code)
            isBlocked = try container.decodeIfPresent(Bool.self, forKey: .isBlocked) ?? false
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(domain, forKey: .domain)
            try container.encode(code, forKey: .code)
            try container.encode(isBlocked, forKey: .isBlocked)
        }
    }

    public enum DeltaEvent: Sendable, Codable {
        /// Chain-of-thought reasoning chunk
        case reasoning(text: String)
        /// Incremental content chunk from the LLM
        case generation(text: String)
        /// Tool call being assembled (streaming deltas)
        case toolCall(delta: ToolCallDelta)

        /// Asynchronous tool execution status update (progress)
        case toolExecution(toolCallID: String, status: ToolExecutionStatus)

        /// Sidecar directive field update (piggy-backed structured output)
        case sidecar(delta: SidecarDelta)

        /// Compatibility constructor using the legacy tool-call identifier spelling.
        @_disfavoredOverload
        @available(*, deprecated, message: "Use toolExecution(toolCallID:status:).")
        public static func toolExecution(
            toolCallId: String,
            status: ToolExecutionStatus
        ) -> DeltaEvent {
            .toolExecution(toolCallID: toolCallId, status: status)
        }

        private enum CodingKeys: String, CodingKey {
            case reasoning, generation, toolCall, toolExecution, sidecar
        }

        private enum TextCodingKeys: String, CodingKey {
            case text
        }

        private enum DeltaCodingKeys: String, CodingKey {
            case delta
        }

        private enum ToolExecutionCodingKeys: String, CodingKey {
            case toolCallID = "toolCallId"
            case status
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)

            if container.contains(.reasoning) {
                let values = try container.nestedContainer(
                    keyedBy: TextCodingKeys.self,
                    forKey: .reasoning
                )
                self = .reasoning(text: try values.decode(String.self, forKey: .text))
                return
            }

            if container.contains(.generation) {
                let values = try container.nestedContainer(
                    keyedBy: TextCodingKeys.self,
                    forKey: .generation
                )
                self = .generation(text: try values.decode(String.self, forKey: .text))
                return
            }

            if container.contains(.toolCall) {
                let values = try container.nestedContainer(
                    keyedBy: DeltaCodingKeys.self,
                    forKey: .toolCall
                )
                self = .toolCall(delta: try values.decode(ToolCallDelta.self, forKey: .delta))
                return
            }

            if container.contains(.toolExecution) {
                let values = try container.nestedContainer(
                    keyedBy: ToolExecutionCodingKeys.self,
                    forKey: .toolExecution
                )
                self = .toolExecution(
                    toolCallID: try values.decode(String.self, forKey: .toolCallID),
                    status: try values.decode(ToolExecutionStatus.self, forKey: .status)
                )
                return
            }

            if container.contains(.sidecar) {
                let values = try container.nestedContainer(
                    keyedBy: DeltaCodingKeys.self,
                    forKey: .sidecar
                )
                self = .sidecar(delta: try values.decode(SidecarDelta.self, forKey: .delta))
                return
            }

            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Unknown ChatEvent delta case"
            ))
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)

            switch self {
            case let .reasoning(text):
                var values = container.nestedContainer(keyedBy: TextCodingKeys.self, forKey: .reasoning)
                try values.encode(text, forKey: .text)
            case let .generation(text):
                var values = container.nestedContainer(keyedBy: TextCodingKeys.self, forKey: .generation)
                try values.encode(text, forKey: .text)
            case let .toolCall(delta):
                var values = container.nestedContainer(keyedBy: DeltaCodingKeys.self, forKey: .toolCall)
                try values.encode(delta, forKey: .delta)
            case let .toolExecution(toolCallID, status):
                var values = container.nestedContainer(
                    keyedBy: ToolExecutionCodingKeys.self,
                    forKey: .toolExecution
                )
                try values.encode(toolCallID, forKey: .toolCallID)
                try values.encode(status, forKey: .status)
            case let .sidecar(delta):
                var values = container.nestedContainer(keyedBy: DeltaCodingKeys.self, forKey: .sidecar)
                try values.encode(delta, forKey: .delta)
            }
        }
    }

    public enum MetaEvent: Sendable, Codable {
        /// RAG context metadata — emitted once at the start of the loop
        case generationContext(metadata: ChatMetadata)
        /// Generation completed with metadata (informational).
        ///
        /// - Warning: This case is **never emitted in production**. The runtime emits the
        ///   terminal completion via `.completion(.generationCompleted)` instead. Retained
        ///   only for backward compatibility of `Codable` round-tripping; new consumers
        ///   should switch on `.completion(.generationCompleted)` (PKRR-011).
        @available(*, deprecated, message: "Never emitted in production. Use .completion(.generationCompleted) for terminal completion metadata.")
        case generationCompleted(message: Message, metadata: APIResponseMetadata)
    }

    public enum ErrorEvent: Sendable, Codable {
        /// Tool call failed before execution (e.g. not found, invalid arguments)
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
        /// Generation was explicitly cancelled
        case generationCancelled

        /// Compatibility constructor using the legacy tool-call identifier spelling.
        @_disfavoredOverload
        @available(*, deprecated, message: "Use toolCallError(toolCallID:name:error:).")
        public static func toolCallError(
            toolCallId: String,
            name: String,
            error: String
        ) -> ErrorEvent {
            .toolCallError(toolCallID: toolCallId, name: name, error: error)
        }

        private enum CodingKeys: String, CodingKey {
            case toolCallError, error, generationCancelled
        }

        private enum ToolCallErrorCodingKeys: String, CodingKey {
            case toolCallID = "toolCallId"
            case name, error
        }

        private enum ErrorCodingKeys: String, CodingKey {
            case message, identity
        }

        private struct EmptyPayload: Codable {}

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)

            if container.contains(.toolCallError) {
                let values = try container.nestedContainer(
                    keyedBy: ToolCallErrorCodingKeys.self,
                    forKey: .toolCallError
                )
                self = .toolCallError(
                    toolCallID: try values.decode(String.self, forKey: .toolCallID),
                    name: try values.decode(String.self, forKey: .name),
                    error: try values.decode(String.self, forKey: .error)
                )
                return
            }

            if container.contains(.error) {
                let values = try container.nestedContainer(
                    keyedBy: ErrorCodingKeys.self,
                    forKey: .error
                )
                self = .error(
                    message: try values.decode(String.self, forKey: .message),
                    identity: try values.decodeIfPresent(ChatEvent.ErrorIdentity.self, forKey: .identity)
                )
                return
            }

            if container.contains(.generationCancelled) {
                _ = try container.decode(EmptyPayload.self, forKey: .generationCancelled)
                self = .generationCancelled
                return
            }

            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Unknown ChatEvent error case"
            ))
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)

            switch self {
            case let .toolCallError(toolCallID, name, error):
                var values = container.nestedContainer(
                    keyedBy: ToolCallErrorCodingKeys.self,
                    forKey: .toolCallError
                )
                try values.encode(toolCallID, forKey: .toolCallID)
                try values.encode(name, forKey: .name)
                try values.encode(error, forKey: .error)
            case let .error(message, identity):
                var values = container.nestedContainer(keyedBy: ErrorCodingKeys.self, forKey: .error)
                try values.encode(message, forKey: .message)
                try values.encodeIfPresent(identity, forKey: .identity)
            case .generationCancelled:
                try container.encode(EmptyPayload(), forKey: .generationCancelled)
            }
        }
    }

    public enum CompletionEvent: Sendable, Codable {
        /// Stream completed with final accumulated message and token metadata
        case generationCompleted(message: Message, metadata: APIResponseMetadata)
        /// The provider finished successfully, but the reconstructed assistant text was empty.
        case completedEmpty(finishReason: String?)
        /// Tool execution completed with final status
        case toolExecution(toolCallID: String, status: ToolExecutionStatus)
        /// The ReAct loop exhausted its `maxTurns` budget while tool calls were still pending,
        /// so the agent never produced a tool-free final response. Terminal: emitted exactly
        /// once before the stream closes, in place of `.generationCompleted`, so consumers can
        /// distinguish max-turn exhaustion from normal completion (PKRR-011).
        case maxTurnsReached
        /// The turn ended because at least one tool call was deferred for external (host-side)
        /// execution. Terminal: emitted exactly once before the stream closes, in place of
        /// `.generationCompleted`, so consumers can distinguish deferred external tool work
        /// from normal completion (PKRR-011).
        case deferredForExternalTool

        /// All sidecar directives resolved for the turn (values, declines, failures)
        case sidecarsCompleted(SidecarCompletion)

        /// The entire stream is complete (terminal event).
        ///
        /// - Warning: This case is **never emitted in production**. The runtime signals
        ///   stream completion through the path-specific terminal cases (`.generationCompleted`,
        ///   `.maxTurnsReached`, `.deferredForExternalTool`) or by throwing. Retained only for
        ///   backward compatibility of `Codable` round-tripping (PKRR-011).
        @available(*, deprecated, message: "Never emitted in production. Switch on .generationCompleted / .maxTurnsReached / .deferredForExternalTool for terminal events.")
        case streamCompleted

        /// Compatibility constructor using the legacy tool-call identifier spelling.
        @_disfavoredOverload
        @available(*, deprecated, message: "Use toolExecution(toolCallID:status:).")
        public static func toolExecution(
            toolCallId: String,
            status: ToolExecutionStatus
        ) -> CompletionEvent {
            .toolExecution(toolCallID: toolCallId, status: status)
        }

        private enum CodingKeys: String, CodingKey {
            case generationCompleted, completedEmpty, toolExecution
            case maxTurnsReached, deferredForExternalTool, sidecarsCompleted, streamCompleted
        }

        private enum GenerationCompletedCodingKeys: String, CodingKey {
            case message, metadata
        }

        private enum CompletedEmptyCodingKeys: String, CodingKey {
            case finishReason
        }

        private enum ToolExecutionCodingKeys: String, CodingKey {
            case toolCallID = "toolCallId"
            case status
        }

        private enum UnlabeledCodingKeys: String, CodingKey {
            case value = "_0"
        }

        private struct EmptyPayload: Codable {}

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)

            if container.contains(.generationCompleted) {
                let values = try container.nestedContainer(
                    keyedBy: GenerationCompletedCodingKeys.self,
                    forKey: .generationCompleted
                )
                self = .generationCompleted(
                    message: try values.decode(Message.self, forKey: .message),
                    metadata: try values.decode(APIResponseMetadata.self, forKey: .metadata)
                )
                return
            }

            if container.contains(.completedEmpty) {
                let values = try container.nestedContainer(
                    keyedBy: CompletedEmptyCodingKeys.self,
                    forKey: .completedEmpty
                )
                self = .completedEmpty(
                    finishReason: try values.decodeIfPresent(String.self, forKey: .finishReason)
                )
                return
            }

            if container.contains(.toolExecution) {
                let values = try container.nestedContainer(
                    keyedBy: ToolExecutionCodingKeys.self,
                    forKey: .toolExecution
                )
                self = .toolExecution(
                    toolCallID: try values.decode(String.self, forKey: .toolCallID),
                    status: try values.decode(ToolExecutionStatus.self, forKey: .status)
                )
                return
            }

            if container.contains(.maxTurnsReached) {
                _ = try container.decode(EmptyPayload.self, forKey: .maxTurnsReached)
                self = .maxTurnsReached
                return
            }

            if container.contains(.deferredForExternalTool) {
                _ = try container.decode(EmptyPayload.self, forKey: .deferredForExternalTool)
                self = .deferredForExternalTool
                return
            }

            if container.contains(.sidecarsCompleted) {
                let values = try container.nestedContainer(
                    keyedBy: UnlabeledCodingKeys.self,
                    forKey: .sidecarsCompleted
                )
                self = .sidecarsCompleted(
                    try values.decode(SidecarCompletion.self, forKey: .value)
                )
                return
            }

            if container.contains(.streamCompleted) {
                _ = try container.decode(EmptyPayload.self, forKey: .streamCompleted)
                self = .streamCompleted
                return
            }

            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Unknown ChatEvent completion case"
            ))
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)

            switch self {
            case let .generationCompleted(message, metadata):
                var values = container.nestedContainer(
                    keyedBy: GenerationCompletedCodingKeys.self,
                    forKey: .generationCompleted
                )
                try values.encode(message, forKey: .message)
                try values.encode(metadata, forKey: .metadata)
            case let .completedEmpty(finishReason):
                var values = container.nestedContainer(
                    keyedBy: CompletedEmptyCodingKeys.self,
                    forKey: .completedEmpty
                )
                try values.encodeIfPresent(finishReason, forKey: .finishReason)
            case let .toolExecution(toolCallID, status):
                var values = container.nestedContainer(
                    keyedBy: ToolExecutionCodingKeys.self,
                    forKey: .toolExecution
                )
                try values.encode(toolCallID, forKey: .toolCallID)
                try values.encode(status, forKey: .status)
            case .maxTurnsReached:
                try container.encode(EmptyPayload(), forKey: .maxTurnsReached)
            case .deferredForExternalTool:
                try container.encode(EmptyPayload(), forKey: .deferredForExternalTool)
            case let .sidecarsCompleted(completion):
                var values = container.nestedContainer(
                    keyedBy: UnlabeledCodingKeys.self,
                    forKey: .sidecarsCompleted
                )
                try values.encode(completion, forKey: .value)
            case .streamCompleted:
                try container.encode(EmptyPayload(), forKey: .streamCompleted)
            }
        }
    }

    case delta(DeltaEvent)
    case meta(MetaEvent)
    case error(ErrorEvent)
    case completion(CompletionEvent)
}

// MARK: - Factory Methods (Producer Ergonomics)

public extension ChatEvent {
    /// Delta shortcuts
    static func reasoning(_ text: String) -> ChatEvent {
        .delta(.reasoning(text: text))
    }

    static func generation(_ text: String) -> ChatEvent {
        .delta(.generation(text: text))
    }

    static func toolCall(_ delta: ToolCallDelta) -> ChatEvent {
        .delta(.toolCall(delta: delta))
    }

    static func toolProgress(toolCallID: String, status: ToolExecutionStatus) -> ChatEvent {
        .delta(.toolExecution(toolCallID: toolCallID, status: status))
    }

    /// Compatibility factory using the legacy tool-call identifier spelling.
    @_disfavoredOverload
    @available(*, deprecated, message: "Use toolProgress(toolCallID:status:).")
    static func toolProgress(toolCallId: String, status: ToolExecutionStatus) -> ChatEvent {
        toolProgress(toolCallID: toolCallId, status: status)
    }

    static func sidecar(_ delta: SidecarDelta) -> ChatEvent {
        .delta(.sidecar(delta: delta))
    }

    /// Meta shortcuts
    static func generationContext(_ metadata: ChatMetadata) -> ChatEvent {
        .meta(.generationContext(metadata: metadata))
    }

    /// Error shortcuts
    static func toolCallError(toolCallID: String, name: String, error: String) -> ChatEvent {
        .error(.toolCallError(toolCallID: toolCallID, name: name, error: error))
    }

    /// Compatibility factory using the legacy tool-call identifier spelling.
    @_disfavoredOverload
    @available(*, deprecated, message: "Use toolCallError(toolCallID:name:error:).")
    static func toolCallError(toolCallId: String, name: String, error: String) -> ChatEvent {
        toolCallError(toolCallID: toolCallId, name: name, error: error)
    }

    static func error(_ err: Error) -> ChatEvent {
        .error(.error(
            message: ErrorKit.userFriendlyMessage(for: err),
            identity: ErrorIdentity.extracting(from: err)
        ))
    }

    static func error(_ msg: String) -> ChatEvent {
        .error(.error(message: msg, identity: nil))
    }

    static func generationCancelled() -> ChatEvent {
        .error(.generationCancelled)
    }

    /// Completion shortcuts
    static func generationCompleted(message: Message, metadata: APIResponseMetadata) -> ChatEvent {
        .completion(.generationCompleted(message: message, metadata: metadata))
    }

    static func completedEmpty(finishReason: String?) -> ChatEvent {
        .completion(.completedEmpty(finishReason: finishReason))
    }

    static func toolCompleted(toolCallID: String, status: ToolExecutionStatus) -> ChatEvent {
        .completion(.toolExecution(toolCallID: toolCallID, status: status))
    }

    /// Compatibility factory using the legacy tool-call identifier spelling.
    @_disfavoredOverload
    @available(*, deprecated, message: "Use toolCompleted(toolCallID:status:).")
    static func toolCompleted(toolCallId: String, status: ToolExecutionStatus) -> ChatEvent {
        toolCompleted(toolCallID: toolCallId, status: status)
    }

    static func streamCompleted() -> ChatEvent {
        .completion(.completedEmpty(finishReason: nil))
    }

    static func maxTurnsReached() -> ChatEvent {
        .completion(.maxTurnsReached)
    }

    static func deferredForExternalTool() -> ChatEvent {
        .completion(.deferredForExternalTool)
    }

    static func sidecarsCompleted(_ completion: SidecarCompletion) -> ChatEvent {
        .completion(.sidecarsCompleted(completion))
    }

    /// Compatibility factory for consumers that construct this event directly.
    static func sidecarsCompleted(_ results: [SidecarResult]) -> ChatEvent {
        .sidecarsCompleted(SidecarCompletion(
            identity: TurnIdentity(sendID: UUID(), roundTrip: 0),
            results: results
        ))
    }
}

// MARK: - Computed Properties (Consumer Ergonomics)

public extension ChatEvent {
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

    /// The completed message and metadata if this is a `.completion(.generationCompleted(...))` event.
    var completedMessage: (message: Message, metadata: APIResponseMetadata)? {
        if case let .completion(event) = self, case let .generationCompleted(msg, meta) = event { return (msg, meta) }
        return nil
    }

    /// The finish reason for an empty but successfully completed assistant response, if present.
    var emptyCompletionFinishReason: String? {
        if case let .completion(event) = self, case let .completedEmpty(finishReason) = event { return finishReason }
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
