import Foundation
import PKContracts
import PKUtilities

/// Builds the concrete per-turn runtime pipeline used by `TurnEngine`.
///
/// Keeping pipeline assembly here separates stage-topology policy from the chat loop itself. The
/// `TurnEngine` still decides *when* a turn runs; this helper decides *which* stages make up the
/// default turn pipeline and how package-internal additional stages are appended.
enum TurnPipelineBuilder {
    static func makePipeline(
        llmService: any LLMStreamClient,
        messageStore: any ThreadMessageStoreProtocol,
        streamTimeout: TimeInterval,
        diagnosticSnapshotConfiguration: DiagnosticSnapshotConfiguration = .default,
        loggingConfiguration: LoggingConfiguration = .default,
        additionalStages: [any PipelineStage<TurnContext, TurnEvent>] = []
    ) -> Pipeline<TurnContext, TurnEvent> {
        var pipeline = Pipeline<TurnContext, TurnEvent>()
            .add(LLMStreamingStage(llmService: llmService, streamTimeout: streamTimeout))
            .add(ToolCallExtractionStage())
            .add(MessagePersistenceStage(
                messageStore: messageStore,
                diagnosticSnapshotConfiguration: diagnosticSnapshotConfiguration,
                loggingConfiguration: loggingConfiguration
            ))

        for stage in additionalStages {
            pipeline = pipeline.add(stage)
        }

        return pipeline
    }

}
