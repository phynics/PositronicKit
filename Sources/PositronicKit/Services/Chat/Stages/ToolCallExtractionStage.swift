import Foundation
import Logging
import PKPrompt
import PKShared

private let redactedHash = PKShared.redactedHash

/// Pipeline stage responsible for extracting and normalising tool calls from the LLM response.
///
/// This stage does NOT execute tools. It validates and cleans `context.outputs.toolCallAccumulators`
/// so that `PersistenceStage` and `ChatEngine.runChatLoop` can rely on it:
/// - Falls back to text parsing when the LLM didn't emit structured tool calls.
/// - Strips sentinel and empty-named calls.
/// - Appends records for the debug snapshot.
///
/// Actual execution is handled by `ToolRouter.handlePendingToolCalls()`, called from
/// `ChatEngine.runChatLoop` after the pipeline completes.
struct ToolCallExtractionStage: PipelineStage {
    let logger: Logger

    func process(_ context: ChatTurnContext) async throws -> AsyncThrowingStream<ChatEvent, Error> {
        var eventsToYield: [ChatEvent] = []

        let accumulators = await context.outputs.toolCallAccumulators
        let baseMeta: Logger.Metadata = [
            "conversationID": .string(redactedHash(context.timelineId.uuidString)),
            "turnIndex": .string("\(context.turnCount)"),
        ]
        logger.debug("ToolCallExtractionStage: \(accumulators.count) accumulator(s) before fallback/cleanup", metadata: baseMeta)
        for (index, acc) in accumulators.sorted(by: { $0.key < $1.key }) {
            let name = acc.name.isEmpty ? "(empty)" : acc.name
            var meta = baseMeta
            meta["accumulatorIndex"] = .string("\(index)")
            meta["toolName"] = .string(name)
            meta["callID"] = .string(redactedHash(acc.callId))
            logger.debug(
                "  [accumulator \(index)] id=\(acc.callId) name=\(String(reflecting: name)) argsBytes=\(acc.args.utf8.count)",
                metadata: meta
            )
        }

        // Fallback: parse tool calls from response text when structured calls are absent.
        // Guard: skip fallback entirely when no tools were offered — any <tool_call> markers
        // in the response text are then not legitimate calls and must not bypass approval gates.
        if accumulators.isEmpty, !context.availableTools.isEmpty {
            let fallbackCalls = ToolOutputParser.parse(from: await context.outputs.fullResponse)
            if !fallbackCalls.isEmpty {
                var meta = baseMeta
                meta["fallbackCount"] = .string("\(fallbackCalls.count)")
                logger.warning(
                    "Structured tool calls empty — falling back to text parsing (\(fallbackCalls.count) call(s)).",
                    metadata: meta
                )
                for (index, call) in fallbackCalls.enumerated() {
                    let argsJson =
                        (try? SerializationUtils.jsonEncoder.encode(call.arguments))
                            .flatMap { String(bytes: $0, encoding: .utf8) } ?? "{}"
                    await context.outputs.setToolCallAccumulator(
                        index: index, id: UUID().uuidString, name: call.name, args: argsJson
                    )
                }

                let updatedAccumulators = await context.outputs.toolCallAccumulators
                for (index, value) in updatedAccumulators.sorted(by: { $0.key < $1.key }) {
                    eventsToYield.append(
                        .toolCall(ToolCallDelta(
                            index: index, id: value.callId, name: value.name, arguments: value.args
                        ))
                    )
                }
            }
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
