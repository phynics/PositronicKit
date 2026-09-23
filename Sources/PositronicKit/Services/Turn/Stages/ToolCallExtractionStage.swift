import Foundation
import Logging
import PKPrompt
import PKContracts
import PKUtilities

private let redactedHash = PKUtilities.redactedHash

/// Pipeline stage responsible for extracting and normalising tool calls from the LLM response.
///
/// This stage does NOT execute tools. It validates and cleans `context.outputs.toolCallAccumulators`
/// so that `MessagePersistenceStage` and `TurnEngine.runTurnLoop` can rely on it:
/// - Strips sentinel and empty-named calls.
/// - Leaves durable tool auditing to `TimelineRuntimeRepository`.
///
/// Actual execution is handled by `ToolRouter.handlePendingToolCalls()`, called from
/// `TurnEngine.runTurnLoop` after the pipeline completes.
struct ToolCallExtractionStage: PipelineStage {
    let logger: Logger

    init(logger: Logger? = nil) {
        self.logger = logger ?? Logger.module(named: "tool-call-extraction")
    }

    func process(_ context: TurnContext) async throws -> AsyncThrowingStream<TurnEvent, Error> {
        let accumulators = await context.outputs.toolCallAccumulators
        // timelineID is logged raw (not hashed) so PKRuntime records correlate
        // end-to-end with Yakamoz logs (YAK-40), which log the raw timelineId. A UUID is
        // an id, not a payload, so logging it raw is YAK-37 compliant.
        let baseMeta: Logger.Metadata = [
            LogKeys.timelineID: .string(context.timelineID.uuidString),
            LogKeys.turnID: .string(context.turnID.uuidString),
            LogKeys.requestID: .string(context.requestId.uuidString),
            LogKeys.modelRoundIndex: .string("\(context.modelRoundIndex)"),
            LogKeys.stage: .string("tool-call-extraction"),
        ]
        logger.debug("ToolCallExtractionStage: \(accumulators.count) accumulator(s) before cleanup", metadata: baseMeta)
        for (index, acc) in accumulators.sorted(by: { $0.key < $1.key }) {
            let name = acc.name.isEmpty ? "(empty)" : acc.name
            var meta = baseMeta
            meta["accumulatorIndex"] = .string("\(index)")
            meta[LogKeys.toolName] = .string(name)
            meta["callID"] = .string(redactedHash(acc.callId))
            logger.debug(
                "  [accumulator \(index)] id=\(acc.callId) name=\(String(reflecting: name)) argsBytes=\(acc.args.utf8.count)",
                metadata: meta
            )
        }

        // Remove sentinel/empty calls so downstream stages see only actionable tool calls.
        let beforeFilter = await context.outputs.toolCallAccumulators.count
        await context.outputs.removeSentinelAndEmptyToolCalls(sentinel: TurnEngine.Constants.sentinelToolName)
        let afterFilter = await context.outputs.toolCallAccumulators.count
        if beforeFilter != afterFilter {
            var meta = baseMeta
            meta["strippedCount"] = .string("\(beforeFilter - afterFilter)")
            logger.info("Stripped \(beforeFilter - afterFilter) sentinel/empty tool-call accumulator(s)", metadata: meta)
        }

        let finalAccumulators = await context.outputs.toolCallAccumulators
        var finalMeta = baseMeta
        finalMeta["finalCount"] = .string("\(finalAccumulators.count)")
        logger.debug("ToolCallExtractionStage: \(finalAccumulators.count) accumulator(s) after cleanup", metadata: finalMeta)

        return AsyncThrowingStream { $0.finish() }
    }
}
