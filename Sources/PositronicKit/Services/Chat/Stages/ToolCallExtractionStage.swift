import Foundation
import Logging
import PKPrompt
import PKShared
import PKUtilities

private let redactedHash = PKUtilities.redactedHash

/// Pipeline stage responsible for extracting and normalising tool calls from the LLM response.
///
/// This stage does NOT execute tools. It validates and cleans `context.outputs.toolCallAccumulators`
/// so that `PersistenceStage` and `ChatEngine.runChatLoop` can rely on it:
/// - Strips sentinel and empty-named calls.
/// - Appends records for the debug snapshot.
///
/// Actual execution is handled by `ToolRouter.handlePendingToolCalls()`, called from
/// `ChatEngine.runChatLoop` after the pipeline completes.
struct ToolCallExtractionStage: PipelineStage {
    let logger: Logger

    init(logger: Logger? = nil) {
        self.logger = logger ?? Logger.module(named: "tool-call-extraction")
    }

    func process(_ context: ChatTurnContext) async throws -> AsyncThrowingStream<ChatEvent, Error> {
        var eventsToYield: [ChatEvent] = []

        let accumulators = await context.outputs.toolCallAccumulators
        // timelineID is logged raw (not hashed) so PositronicKit records correlate
        // end-to-end with Yakamoz logs (YAK-40), which log the raw timelineId. A UUID is
        // an id, not a payload, so logging it raw is YAK-37 compliant.
        let baseMeta: Logger.Metadata = [
            LogKeys.timelineID: .string(context.timelineId.uuidString),
            LogKeys.turnIndex: .string("\(context.turnCount)"),
            LogKeys.stage: .string("tool-call-extraction"),
        ]
        logger.debug("ToolCallExtractionStage: \(accumulators.count) accumulator(s) before fallback/cleanup", metadata: baseMeta)
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
        await context.outputs.removeSentinelAndEmptyToolCalls(sentinel: ChatEngine.Constants.sentinelToolName)
        let afterFilter = await context.outputs.toolCallAccumulators.count
        if beforeFilter != afterFilter {
            var meta = baseMeta
            meta["strippedCount"] = .string("\(beforeFilter - afterFilter)")
            logger.info("Stripped \(beforeFilter - afterFilter) sentinel/empty tool-call accumulator(s)", metadata: meta)
        }

        // Record for the debug snapshot.
        let finalAccumulators = await context.outputs.toolCallAccumulators
        var finalMeta = baseMeta
        finalMeta["finalCount"] = .string("\(finalAccumulators.count)")
        logger.debug("ToolCallExtractionStage: \(finalAccumulators.count) accumulator(s) after cleanup", metadata: finalMeta)
        for (_, value) in finalAccumulators.sorted(by: { $0.key < $1.key }) {
            await context.outputs.addDebugToolCall(
                ToolCallRecord(name: value.name, arguments: value.args, turn: context.turnCount)
            )
        }

        return AsyncThrowingStream { continuation in
            for event in eventsToYield {
                continuation.yield(event)
            }
            continuation.finish()
        }
    }
}
