import PKShared
import ErrorKit
import Foundation

/// Log levels for pipeline diagnostics.
public enum PipelineLogLevel: Sendable {
    case trace, debug, info, notice, warning, error, critical
}

/// Protocol defining a single stage in a pipeline.
public protocol PipelineStage<Context, Event>: Sendable {
    associatedtype Context: Sendable
    associatedtype Event: Sendable

    /// Unique identifier for the stage.
    var id: String { get }

    /// Processes the given context.
    /// - Parameters:
    ///   - context: The context to be processed and potentially modified.
    /// - Returns: A stream of events emitted during processing.
    /// - Throws: An error if processing fails.
    func process(_ context: Context) async throws -> AsyncThrowingStream<Event, Error>
}

public extension PipelineStage {
    /// Default implementation returns the type name.
    var id: String {
        String(describing: Self.self)
    }
}

/// A generic, asynchronous pipeline that executes a series of stages.
public final class Pipeline<Context: Sendable, Event: Sendable>: Sendable {
    public typealias LogHandler = @Sendable (PipelineLogLevel, String, [String: String]) -> Void

    private let stages: [any PipelineStage<Context, Event>]
    private let cleanupStages: [any PipelineStage<Context, Event>]
    private let logHandler: LogHandler?

    public init(
        stages: [any PipelineStage<Context, Event>] = [],
        cleanupStages: [any PipelineStage<Context, Event>] = [],
        logHandler: LogHandler? = nil
    ) {
        self.stages = stages
        self.cleanupStages = cleanupStages
        self.logHandler = logHandler
    }

    /// Adds a stage to the pipeline and returns a new pipeline instance.
    /// - Parameter stage: The stage to add.
    /// - Returns: A new pipeline instance with the added stage.
    public func add(_ stage: any PipelineStage<Context, Event>) -> Pipeline<Context, Event> {
        Pipeline(stages: stages + [stage], cleanupStages: cleanupStages, logHandler: logHandler)
    }

    /// Adds a cleanup stage to the pipeline and returns a new pipeline instance.
    /// Cleanup stages are executed even if a primary stage fails.
    /// - Parameter stage: The cleanup stage to add.
    /// - Returns: A new pipeline instance with the added cleanup stage.
    public func cleanup(_ stage: any PipelineStage<Context, Event>) -> Pipeline<Context, Event> {
        Pipeline(stages: stages, cleanupStages: cleanupStages + [stage], logHandler: logHandler)
    }

    /// Sets the log handler for the pipeline and returns a new pipeline instance.
    /// - Parameter handler: The log handler closure.
    /// - Returns: A new pipeline instance with the log handler set.
    public func withLogHandler(_ handler: @escaping LogHandler) -> Pipeline<Context, Event> {
        Pipeline(stages: stages, cleanupStages: cleanupStages, logHandler: handler)
    }

    /// Executes the pipeline on the given context.
    /// - Parameters:
    ///   - context: The context to process.
    /// - Returns: A merged stream of all events from all stages.
    public func execute(_ context: Context) -> AsyncThrowingStream<Event, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let executionError = await runPrimaryStages(context: context, continuation: continuation)
                let finalError = await runCleanupStages(
                    context: context, continuation: continuation, priorError: executionError
                )

                if let error = finalError {
                    continuation.finish(throwing: error)
                } else {
                    continuation.finish()
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    // MARK: - Execution Helpers

    private func runPrimaryStages(
        context: Context,
        continuation: AsyncThrowingStream<Event, Error>.Continuation
    ) async -> Error? {
        for stage in stages {
            if Task.isCancelled { break }
            if let error = await runStage(stage, context: context, continuation: continuation, label: "pipeline") {
                return error
            }
        }
        return nil
    }

    private func runCleanupStages(
        context: Context,
        continuation: AsyncThrowingStream<Event, Error>.Continuation,
        priorError: Error?
    ) async -> Error? {
        var finalError = priorError
        for stage in cleanupStages {
            if let error = await runStage(stage, context: context, continuation: continuation, label: "cleanup") {
                if finalError == nil {
                    finalError = error
                }
            }
        }
        return finalError
    }

    private func runStage(
        _ stage: any PipelineStage<Context, Event>,
        context: Context,
        continuation: AsyncThrowingStream<Event, Error>.Continuation,
        label: String
    ) async -> Error? {
        let startTime = Date().timeIntervalSinceReferenceDate
        logHandler?(.debug, "Starting \(label) stage: \(stage.id)", [:])

        do {
            let stream = try await stage.process(context)
            for try await event in stream {
                continuation.yield(event)
            }
            let duration = Date().timeIntervalSinceReferenceDate - startTime
            logHandler?(.debug, "Completed \(label) stage: \(stage.id) in \(String(format: "%.3f", duration))s", [:])
            return nil
        } catch {
            let duration = Date().timeIntervalSinceReferenceDate - startTime
            let durationStr = String(format: "%.3f", duration)
            logHandler?(.error, "\(label) stage '\(stage.id)' failed after \(durationStr)s: \(error.localizedDescription)", [:])

            // If it's already a PipelineError, propagate it directly to avoid double wrapping
            if let pipelineError = error as? PipelineError {
                return pipelineError
            }

            if label == "cleanup" {
                return PipelineError.cleanupFailed(id: stage.id, underlyingError: error)
            } else {
                return PipelineError.stageFailed(id: stage.id, underlyingError: error)
            }
        }
    }
}

/// Errors that can occur during pipeline execution.
public enum PipelineError: Error, Sendable {
    case stageFailed(id: String, underlyingError: Error)
    case cleanupFailed(id: String, underlyingError: Error)
}

extension PipelineError: PKError {
    public var errorDomain: String {
        PKErrorDomain.pipeline
    }

    public var errorCode: Int {
        switch self {
        case .stageFailed: return 4001
        case .cleanupFailed: return 4002
        }
    }

    public var userFriendlyMessage: String {
        switch self {
        case let .stageFailed(id, underlyingError):
            return "Pipeline stage '\(id)' failed: \(ErrorKit.userFriendlyMessage(for: underlyingError))"
        case let .cleanupFailed(id, underlyingError):
            return "Pipeline cleanup stage '\(id)' failed: \(ErrorKit.userFriendlyMessage(for: underlyingError))"
        }
    }
}
