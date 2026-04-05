import Foundation
import Logging
import MonadPrompt
import MonadShared
import OpenAI

/// Pipeline stage responsible for streaming the response from the LLM and parsing deltas.
struct LLMStreamingStage: PipelineStage {
    let llmService: any LLMServiceProtocol
    let logger: Logger

    func process(_ context: ChatTurnContext) async throws -> AsyncThrowingStream<ChatEvent, Error> {
        let streamData = await llmService.chatStream(
            messages: context.currentMessages,
            tools: context.toolParams.isEmpty ? nil : context.toolParams,
            responseFormat: nil,
            generationParameters: context.generationParameters
        )

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var parser = StreamingParser()
                    let turnStartTime = Date()

                    for try await result in streamData {
                        if Task.isCancelled { break }

                        await handleStreamUsage(result, context: context)
                        await handleContentDelta(result, parser: &parser, context: context, continuation: continuation)
                        await handleToolCallDeltas(result, context: context, continuation: continuation)
                    }

                    await flushRemainingBuffer(&parser, context: context, continuation: continuation)

                    await context.outputs.finalizeTurn(startTime: turnStartTime)

                    // Task cancellation after natural stream completion is not an error.
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    // MARK: - Helpers

    private func handleStreamUsage(_ result: ChatStreamResult, context: ChatTurnContext) async {
        if let usage = result.usage {
            await context.outputs.setStreamUsage(usage)
        }
    }

    private func handleContentDelta(
        _ result: ChatStreamResult,
        parser: inout StreamingParser,
        context: ChatTurnContext,
        continuation: AsyncThrowingStream<ChatEvent, Error>.Continuation
    ) async {
        guard let delta = result.choices.first?.delta.content else { return }

        let oldThinkingCount = parser.thinking.count
        let oldContentCount = parser.content.count

        parser.process(delta)

        let thinkingChunk: Substring
        let contentChunk: Substring

        if parser.hasReclassified {
            thinkingChunk = parser.thinking.dropFirst(oldThinkingCount)
            contentChunk = ""
        } else {
            thinkingChunk = parser.thinking.dropFirst(oldThinkingCount)
            contentChunk = parser.content.dropFirst(oldContentCount)
        }

        if !thinkingChunk.isEmpty {
            await context.outputs.appendThinking(String(thinkingChunk))
            continuation.yield(.thinking(String(thinkingChunk)))
        }

        if !contentChunk.isEmpty {
            await context.outputs.appendResponse(String(contentChunk))
            continuation.yield(.generation(String(contentChunk)))
        }
    }

    private func handleToolCallDeltas(
        _ result: ChatStreamResult,
        context: ChatTurnContext,
        continuation: AsyncThrowingStream<ChatEvent, Error>.Continuation
    ) async {
        guard let calls = result.choices.first?.delta.toolCalls else { return }
        for call in calls {
            guard let index = call.index else { continue }
            await context.outputs.accumulateToolCall(
                index: index,
                id: call.id,
                name: call.function?.name,
                args: call.function?.arguments
            )
            continuation.yield(.toolCall(ToolCallDelta(
                index: index,
                id: call.id,
                name: call.function?.name,
                arguments: call.function?.arguments
            )))
        }
    }

    private func flushRemainingBuffer(
        _ parser: inout StreamingParser,
        context: ChatTurnContext,
        continuation: AsyncThrowingStream<ChatEvent, Error>.Continuation
    ) async {
        guard !parser.buffer.isEmpty else { return }
        if parser.isThinking {
            let buffer = parser.buffer
            await context.outputs.appendThinking(buffer)
            continuation.yield(.thinking(parser.buffer))
        } else {
            let buffer = parser.buffer
            await context.outputs.appendResponse(buffer)
            continuation.yield(.generation(parser.buffer))
        }
    }
}
