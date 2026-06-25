import Foundation
import Logging
import PKPrompt
import PKShared

/// Pipeline stage responsible for streaming the response from the LLM and parsing deltas.
struct LLMStreamingStage: PipelineStage {
    let llmService: any LLMServiceProtocol
    let logger: Logger
    let streamTimeout: TimeInterval

    init(llmService: any LLMServiceProtocol, logger: Logger, streamTimeout: TimeInterval = 60) {
        self.llmService = llmService
        self.logger = logger
        self.streamTimeout = streamTimeout
    }

    func process(_ context: ChatTurnContext) async throws -> AsyncThrowingStream<ChatEvent, Error> {
        let streamData: AsyncThrowingStream<LLMStreamChunk, Error>
        if let structuredOutput = context.structuredOutput {
            streamData = await llmService.chatStream(
                messages: context.currentMessages,
                tools: context.toolParams.isEmpty ? nil : context.toolParams,
                structuredOutput: structuredOutput,
                generationParameters: context.generationParameters
            )
        } else {
            streamData = await llmService.chatStream(
                messages: context.currentMessages,
                tools: context.toolParams.isEmpty ? nil : context.toolParams,
                responseFormat: nil,
                generationParameters: context.generationParameters
            )
        }

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    // `streamTimeout` is an *inactivity* (idle) timeout, not a total cap: the
                    // deadline is pushed forward on every received chunk, so a slow-but-
                    // progressing long generation (or a reasoning model that streams steadily for
                    // minutes) is never killed — only a genuine hang where no data arrives for
                    // `streamTimeout` triggers `streamTimedOut`.
                    let clock = ContinuousClock()
                    let deadline = StreamIdleDeadline(timeout: streamTimeout, clock: clock)
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        group.addTask {
                            try await streamResponse(
                                streamData,
                                context: context,
                                continuation: continuation,
                                idleDeadline: deadline
                            )
                        }
                        group.addTask {
                            while true {
                                let remaining = await deadline.remaining()
                                if remaining <= .zero {
                                    throw ChatEngineError.streamTimedOut(streamTimeout)
                                }
                                try await Task.sleep(for: remaining, clock: clock)
                            }
                        }

                        _ = try await group.next()
                        group.cancelAll()
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    // MARK: - Helpers

    private func streamResponse(
        _ streamData: AsyncThrowingStream<LLMStreamChunk, Error>,
        context: ChatTurnContext,
        continuation: AsyncThrowingStream<ChatEvent, Error>.Continuation,
        idleDeadline: StreamIdleDeadline
    ) async throws {
        var parser = StreamingParser()
        let turnStartTime = Date()

        for try await result in streamData {
            if Task.isCancelled { break }
            // Reset the inactivity deadline: progress was made this chunk.
            await idleDeadline.reset()

            await handleStreamUsage(result, context: context)
            await handleContentDelta(result, parser: &parser, context: context, continuation: continuation)
            await handleToolCallDeltas(result, context: context, continuation: continuation)
        }

        await flushRemainingBuffer(&parser, context: context, continuation: continuation)
        await context.outputs.finalizeTurn(startTime: turnStartTime)
    }

    private func handleStreamUsage(_ result: LLMStreamChunk, context: ChatTurnContext) async {
        if let usage = result.usage {
            await context.outputs.setStreamUsage(usage)
        }
    }

    private func handleContentDelta(
        _ result: LLMStreamChunk,
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
        _ result: LLMStreamChunk,
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
        let kind = parser.isThinking ? "thinking" : "content"
        logger.debug("Flushing remaining \(kind) buffer (\(parser.buffer.count) chars)")
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

private actor StreamIdleDeadline {
    private let timeout: TimeInterval
    private let clock: ContinuousClock
    private var deadline: ContinuousClock.Instant

    init(timeout: TimeInterval, clock: ContinuousClock) {
        self.timeout = timeout
        self.clock = clock
        deadline = clock.now.advanced(by: .seconds(timeout))
    }

    func reset() {
        deadline = clock.now.advanced(by: .seconds(timeout))
    }

    func remaining() -> Duration {
        deadline - clock.now
    }
}
