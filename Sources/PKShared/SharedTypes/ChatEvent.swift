import ErrorKit
import Foundation

public enum ToolExecutionStatus: Sendable, Codable {
    case attempting(name: String, reference: ToolReference)
    case success(ToolResult)
    case failed(reference: ToolReference, error: String)
    case failure(String)
}

/// Events emitted by ChatEngine during a chat turn.
///
/// Events are categorized into four groups:
/// - `delta`: Incremental streaming events (text, thinking, tool calls, tool progress)
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
    /// `Equatable`, and `Codable` without carrying an untyped `Error`. Extraction is
    /// a single top-level `as? any PKError` cast: the in-use "blocked" error types
    /// (`ToolError.permissionDenied`, `PathError.accessDenied`,
    /// `WorkspaceError.accessDenied`, `ToolError.attachedToolsDisallowedOnPrivateTimeline`)
    /// are all thrown directly and conform to `PKError`, so a single cast covers the
    /// production classification. Nested causes are not dug — non-`PKError` errors
    /// (including provider failures) yield `identity == nil` and are intentionally
    /// not classified as blocked (see `blockedIdentityContract`).
    public struct ErrorIdentity: Sendable, Equatable, Hashable, Codable {
        /// The error domain identifying the module the error originated in
        /// (a `PKErrorDomain` string, e.g. `"com.positronickit.core.tool"`).
        public let domain: String
        /// A unique integer code for the specific error case within the domain.
        public let code: Int

        public init(domain: String, code: Int) {
            self.domain = domain
            self.code = code
        }

        /// Extracts an `ErrorIdentity` from `error` when its top-level type conforms
        /// to `PKError`; returns `nil` for non-`PKError` errors. Nested causes are
        /// not traversed (see the type's documented limitation).
        public static func extracting(from error: Error) -> ErrorIdentity? {
            if let pk = error as? any PKError {
                return ErrorIdentity(domain: pk.errorDomain, code: pk.errorCode)
            }
            return nil
        }
    }

    public enum DeltaEvent: Sendable, Codable {
        /// Chain-of-thought reasoning chunk
        case thinking(text: String)
        /// Incremental content chunk from the LLM
        case generation(text: String)
        /// Tool call being assembled (streaming deltas)
        case toolCall(delta: ToolCallDelta)

        /// Asynchronous tool execution status update (progress)
        case toolExecution(toolCallId: String, status: ToolExecutionStatus)

        /// Sidecar directive field update (piggy-backed structured output)
        case sidecar(delta: SidecarDelta)
    }

    public enum MetaEvent: Sendable, Codable {
        /// RAG context metadata — emitted once at the start of the loop
        case generationContext(metadata: ChatMetadata)
        /// Generation completed with metadata (informational)
        case generationCompleted(message: Message, metadata: APIResponseMetadata)
    }

    public enum ErrorEvent: Sendable, Codable {
        /// Tool call failed before execution (e.g. not found, invalid arguments)
        case toolCallError(toolCallId: String, name: String, error: String)
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
    }

    public enum CompletionEvent: Sendable, Codable {
        /// Stream completed with final accumulated message and token metadata
        case generationCompleted(message: Message, metadata: APIResponseMetadata)
        /// Tool execution completed with final status
        case toolExecution(toolCallId: String, status: ToolExecutionStatus)
        /// The entire stream is complete (terminal event)
        case streamCompleted

        /// All sidecar directives resolved for the turn (values, declines, failures)
        case sidecarsCompleted(results: [SidecarResult])
    }

    case delta(event: DeltaEvent)
    case meta(event: MetaEvent)
    case error(event: ErrorEvent)
    case completion(event: CompletionEvent)
}

// MARK: - Factory Methods (Producer Ergonomics)

public extension ChatEvent {
    /// Delta shortcuts
    static func thinking(_ text: String) -> ChatEvent {
        .delta(event: .thinking(text: text))
    }

    static func generation(_ text: String) -> ChatEvent {
        .delta(event: .generation(text: text))
    }

    static func toolCall(_ delta: ToolCallDelta) -> ChatEvent {
        .delta(event: .toolCall(delta: delta))
    }

    static func toolProgress(toolCallId: String, status: ToolExecutionStatus) -> ChatEvent {
        .delta(event: .toolExecution(toolCallId: toolCallId, status: status))
    }

    static func sidecar(_ delta: SidecarDelta) -> ChatEvent {
        .delta(event: .sidecar(delta: delta))
    }

    /// Meta shortcuts
    static func generationContext(_ metadata: ChatMetadata) -> ChatEvent {
        .meta(event: .generationContext(metadata: metadata))
    }

    /// Error shortcuts
    static func toolCallError(toolCallId: String, name: String, error: String) -> ChatEvent {
        .error(event: .toolCallError(toolCallId: toolCallId, name: name, error: error))
    }

    static func error(_ err: Error) -> ChatEvent {
        .error(event: .error(
            message: ErrorKit.userFriendlyMessage(for: err),
            identity: ErrorIdentity.extracting(from: err)
        ))
    }

    static func error(_ msg: String) -> ChatEvent {
        .error(event: .error(message: msg, identity: nil))
    }

    static func generationCancelled() -> ChatEvent {
        .error(event: .generationCancelled)
    }

    /// Completion shortcuts
    static func generationCompleted(message: Message, metadata: APIResponseMetadata) -> ChatEvent {
        .completion(event: .generationCompleted(message: message, metadata: metadata))
    }

    static func toolCompleted(toolCallId: String, status: ToolExecutionStatus) -> ChatEvent {
        .completion(event: .toolExecution(toolCallId: toolCallId, status: status))
    }

    static func streamCompleted() -> ChatEvent {
        .completion(event: .streamCompleted)
    }

    static func sidecarsCompleted(_ results: [SidecarResult]) -> ChatEvent {
        .completion(event: .sidecarsCompleted(results: results))
    }
}

// MARK: - Computed Properties (Consumer Ergonomics)

public extension ChatEvent {
    /// The text content if this is a `.delta(.generation(...))` event.
    var textContent: String? {
        if case let .delta(event) = self, case let .generation(text) = event { return text }
        return nil
    }

    /// The thinking content if this is a `.delta(.thinking(...))` event.
    var thinkingContent: String? {
        if case let .delta(event) = self, case let .thinking(text) = event { return text }
        return nil
    }

    /// The completed message and metadata if this is a `.completion(.generationCompleted(...))` event.
    var completedMessage: (message: Message, metadata: APIResponseMetadata)? {
        if case let .completion(event) = self, case let .generationCompleted(msg, meta) = event { return (msg, meta) }
        return nil
    }

    /// The sidecar delta if this is a `.delta(.sidecar(...))` event.
    var sidecarDelta: SidecarDelta? {
        if case let .delta(event) = self, case let .sidecar(delta) = event { return delta }
        return nil
    }

    /// The sidecar results if this is a `.completion(.sidecarsCompleted(...))` event.
    var sidecarResults: [SidecarResult]? {
        if case let .completion(event) = self, case let .sidecarsCompleted(results) = event { return results }
        return nil
    }
}

// MARK: - Blocked Error Identity Contract (STAB-6)

public extension ChatEvent.ErrorIdentity {
    /// Error identities that represent a "blocked"/approval/disallowed turn condition —
    /// i.e. a failure that is *not* the model's or provider's fault but the result of a
    /// deliberate permission or access gate refusing execution. Consumers classify these
    /// as a `.blocked` timeline state rather than `.failed`.
    ///
    /// Each entry is the `(domain, code)` pair of a structured `PKError` that is thrown
    /// directly by the runtime (grep evidence):
    /// - `ToolError.permissionDenied` — `com.positronickit.core.tool:210`
    ///   (thrown at `PositronicKit/Sources/PositronicKit/Services/Tools/ToolRouter.swift:343`)
    /// - `ToolError.attachedToolsDisallowedOnPrivateTimeline` — `com.positronickit.core.tool:207`
    ///   (thrown at `PositronicKit/Sources/PositronicKit/Services/Tools/ToolRoutingDecision.swift:27`)
    /// - `PathError.accessDenied` — `com.positronickit.core.filesystem:101`
    ///   (thrown at `PositronicKit/Sources/PKShared/Utilities/PathSanitizer.swift:46,60`)
    /// - `WorkspaceError.accessDenied` — `com.positronickit.core.workspace:3002`
    ///   (declared at `PositronicKit/Sources/PositronicKit/Models/Workspace/WorkspaceProtocol.swift:41`)
    static let blocked: Set<ChatEvent.ErrorIdentity> = [
        ChatEvent.ErrorIdentity(domain: PKErrorDomain.tool, code: 210),
        ChatEvent.ErrorIdentity(domain: PKErrorDomain.tool, code: 207),
        ChatEvent.ErrorIdentity(domain: PKErrorDomain.filesystem, code: 101),
        ChatEvent.ErrorIdentity(domain: PKErrorDomain.workspace, code: 3002),
    ]

    /// Whether this identity represents a blocked/approval/disallowed condition (see `blocked`).
    var isBlocked: Bool {
        Self.blocked.contains(self)
    }
}
