import Foundation
import PKShared
import PKUtilities

/// Builds the concrete per-turn runtime pipeline used by `ChatEngine`.
///
/// Keeping pipeline assembly here separates stage-topology policy from the chat loop itself. The
/// `ChatEngine` still decides *when* a turn runs; this helper decides *which* stages make up the
/// default turn pipeline and how package-internal additional stages are appended.
enum ChatTurnPipelineBuilder {
    static func makePipeline(
        llmService: any LLMStreamClient,
        messageStore: any MessageStoreProtocol,
        streamTimeout: TimeInterval,
        additionalStages: [any PipelineStage<ChatTurnContext, ChatEvent>] = []
    ) -> Pipeline<ChatTurnContext, ChatEvent> {
        var pipeline = Pipeline<ChatTurnContext, ChatEvent>()
            .add(LLMStreamingStage(llmService: llmService, streamTimeout: streamTimeout))
            .add(ToolCallExtractionStage())
            .add(MessagePersistenceStage(messageStore: messageStore))

        for stage in additionalStages {
            pipeline = pipeline.add(stage)
        }

        return pipeline
    }
}
