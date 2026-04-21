import Foundation
import PKPrompt
import PKShared

/// Events emitted during the prompt assembly process.
public enum PromptAssemblyEvent: Sendable {
    /// Indicates a specific stage has started processing.
    /// - Parameter stageID: The unique identifier of the stage.
    case stageStarted(String)
    /// Indicates a specific stage has completed processing.
    /// - Parameter stageID: The unique identifier of the stage.
    case stageCompleted(String)
}

/// Manages the shared state during prompt assembly.
/// This actor holds the request context and accumulates rendered sections.
public actor PromptAssemblyContext: Sendable {
    /// The original prompt request containing user input and context.
    public let request: LLMPromptRequest
    /// The agent instance associated with the prompt, if any.
    public let agentInstance: AgentInstance?
    /// The conversation timeline context, if any.
    public let timeline: Timeline?
    /// Additional context sections provided by extensions or plugins.
    public let extensionSections: [any Prompt]
    /// The ordered collection of gathered prompt sections.
    public private(set) var sections: [any Prompt] = []

    /// Initializes a new prompt assembly context.
    /// - Parameters:
    ///   - request: The prompt request data.
    ///   - agentInstance: Optional agent instance for identity injection.
    ///   - timeline: Optional timeline for conversation context.
    ///   - extensionSections: Optional additional sections from extensions.
    public init(
        request: LLMPromptRequest,
        agentInstance: AgentInstance? = nil,
        timeline: Timeline? = nil,
        extensionSections: [any Prompt] = []
    ) {
        self.request = request
        self.agentInstance = agentInstance
        self.timeline = timeline
        self.extensionSections = extensionSections
    }

    /// Appends a single section to the assembled prompt.
    /// - Parameter section: The context section to add.
    public func append(_ section: any Prompt) {
        sections.append(section)
    }

    /// Appends multiple sections to the assembled prompt.
    /// - Parameter sections: An array of context sections to add.
    public func append(_ sections: [any Prompt]) {
        self.sections.append(contentsOf: sections)
    }
}

/// A specialized pipeline for orchestrating the assembly of an LLM prompt.
public typealias PromptAssemblyPipeline = Pipeline<PromptAssemblyContext, PromptAssemblyEvent>

/// Protocol defining a single stage in the prompt assembly pipeline.
/// Stages are responsible for retrieving specific pieces of context and appending them as sections.
public protocol PromptAssemblyStage: PipelineStage where Context == PromptAssemblyContext, Event == PromptAssemblyEvent {
    /// Executes the assembly logic for this stage.
    /// - Parameter context: The shared assembly context to modify.
    func execute(_ context: PromptAssemblyContext) async throws
}

public extension PromptAssemblyStage {
    /// Default implementation returns the type name of the stage.
    var id: String {
        String(describing: Self.self)
    }

    /// Implements the `PipelineStage` requirement by wrapping `execute` in lifecycle events.
    /// - Parameter context: The shared assembly context.
    /// - Returns: A stream emitting start and completion events.
    func process(_ context: PromptAssemblyContext) async throws -> AsyncThrowingStream<PromptAssemblyEvent, Error> {
        try await running(context) {
            try await execute(context)
        }
    }

    /// Helper that manages the execution lifecycle and yields start/complete events.
    /// - Parameters:
    ///   - context: The shared assembly context.
    ///   - action: The actual work to perform within the stage.
    /// - Returns: A stream that yields `.stageStarted` and `.stageCompleted`.
    func running(_: PromptAssemblyContext, action: @escaping @Sendable () async throws -> Void) async throws -> AsyncThrowingStream<PromptAssemblyEvent, Error> {
        let id = self.id
        return AsyncThrowingStream { continuation in
            let task = Task {
                continuation.yield(.stageStarted(id))
                do {
                    try await action()
                    continuation.yield(.stageCompleted(id))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
}

/// A result builder for constructing prompt assembly pipelines from stages.
public typealias PromptAssemblyPipelineBuilder = PipelineBuilder<PromptAssemblyContext, PromptAssemblyEvent>
