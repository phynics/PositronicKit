import Foundation
import Logging
import PKPrompt
import PKShared
import PKUtilities

/// Pipeline stage responsible for assembling the gathered results into a final `ContextData` object.
struct ContextAssemblyStage: PipelineStage {
    /// Logger for assembly progress.
    let logger: Logger

    /// Initializes a new assembly stage.
    /// - Parameter logger: The logger to use.
    init(logger: Logger) {
        self.logger = logger
    }

    /// Processes the context and yields a completion event with final data.
    /// - Parameter context: The shared pipeline context.
    /// - Returns: A stream that yields the final result.
    func process(
        _ context: ContextPipelineContext
    ) async throws -> AsyncThrowingStream<ContextGatheringEvent, Error> {
        let startTime = context.startTime
        let duration = Date().timeIntervalSinceReferenceDate - startTime
        logger.info("Context gathered in \(String(format: "%.3f", duration))s")

        await context.finalize(executionTime: duration)
        return AsyncThrowingStream { $0.finish() }
    }
}
