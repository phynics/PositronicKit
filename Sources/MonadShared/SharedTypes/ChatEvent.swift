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
    public enum DeltaEvent: Sendable, Codable {
        /// Chain-of-thought reasoning chunk
        case thinking(text: String)
        /// Incremental content chunk from the LLM
        case generation(text: String)
        /// Tool call being assembled (streaming deltas)
        case toolCall(delta: ToolCallDelta)

        /// Asynchronous tool execution status update (progress)
        case toolExecution(toolCallId: String, status: ToolExecutionStatus)
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
        /// General error occurred
        case error(message: String)
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

    /// Meta shortcuts
    static func generationContext(_ metadata: ChatMetadata) -> ChatEvent {
        .meta(event: .generationContext(metadata: metadata))
    }

    /// Error shortcuts
    static func toolCallError(toolCallId: String, name: String, error: String) -> ChatEvent {
        .error(event: .toolCallError(toolCallId: toolCallId, name: name, error: error))
    }

    static func error(_ err: Error) -> ChatEvent {
        .error(event: .error(message: err.localizedDescription))
    }

    static func error(_ msg: String) -> ChatEvent {
        .error(event: .error(message: msg))
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
}
