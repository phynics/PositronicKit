import Foundation
import Logging
import MonadPrompt
import MonadShared
import OpenAI

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

        // Fallback: parse tool calls from response text when structured calls are absent.
        let accumulators = await context.outputs.toolCallAccumulators
        if accumulators.isEmpty {
            let fallbackCalls = ToolOutputParser.parse(from: await context.outputs.fullResponse)
            if !fallbackCalls.isEmpty {
                logger.warning(
                    "Structured tool calls empty — falling back to text parsing (\(fallbackCalls.count) call(s))."
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
        await context.outputs.removeSentinelAndEmptyToolCalls(sentinel: ChatEngine.Constants.sentinelToolName)

        // Record for the debug snapshot.
        let finalAccumulators = await context.outputs.toolCallAccumulators
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
