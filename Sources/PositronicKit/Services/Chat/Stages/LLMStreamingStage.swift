import Foundation
import Logging
import PKPrompt
import PKShared

/// Pipeline stage responsible for streaming the response from the LLM and parsing deltas.
struct LLMStreamingStage: PipelineStage {
    let llmService: any LLMServiceProtocol
    let logger: Logger
    let streamTimeout: TimeInterval

    init(llmService: any LLMServiceProtocol, logger: Logger, streamTimeout: TimeInterval) {
        self.llmService = llmService
        self.logger = logger
        self.streamTimeout = streamTimeout
    }

    func process(_ context: ChatTurnContext) async throws -> AsyncThrowingStream<ChatEvent, Error> {
        let streamData: AsyncThrowingStream<LLMStreamChunk, Error>
        // ChatEngine's entry point rejects turns that set both `structuredOutput` and
        // `sidecars` (SidecarError.conflictsWithExplicitStructuredOutput), so at most one
        // of these is non-nil/non-empty here.
        let effectiveStructuredOutput: StructuredOutputRequest? =
            if context.sidecars.isEmpty {
                context.structuredOutput
            } else {
                try SidecarSchemaComposer.compose(directives: context.sidecars)
            }
        if let structuredOutput = effectiveStructuredOutput {
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
        var sidecarExtractor: SidecarStreamExtractor? = context.sidecars.isEmpty
            ? nil
            : SidecarStreamExtractor(directives: context.sidecars)
        let turnStartTime = Date()

        for try await result in streamData {
            // Cooperative cancellation: throw out of the stage so `ChatEngine`'s catch path
            // persists the partial turn as `.cancelled` + surfaces `.generationCancelled()`
            // (STAB-1). Mirrors the `.streamTimedOut` throw path: the throw exits before
            // `flushRemainingBuffer`/`finalizeTurn`, and the enclosing `do/catch` finishes the
            // continuation with the error — `Task.isCancelled { break }` would instead fall
            // through to `finalizeTurn` and persist a truncated turn as `.complete`.
            if Task.isCancelled { throw CancellationError() }
            // Reset the inactivity deadline: progress was made this chunk.
            await idleDeadline.reset()
            if let finishReason = result.choices.first?.finishReason {
                await context.outputs.setStreamFinishReason(finishReason)
            }

            await handleStreamUsage(result, context: context)
            await handleStructuredThinkingDelta(result, context: context, continuation: continuation)
            if sidecarExtractor != nil {
                await handleSidecarContentDelta(
                    result, extractor: &sidecarExtractor, context: context, continuation: continuation
                )
            } else {
                await handleContentDelta(result, parser: &parser, context: context, continuation: continuation)
            }
            await handleToolCallDeltas(result, context: context, continuation: continuation)
        }

        if var extractor = sidecarExtractor {
            for output in extractor.finish() {
                await routeSidecarOutput(output, context: context, continuation: continuation)
            }
        } else {
            await flushRemainingBuffer(&parser, context: context, continuation: continuation)
        }
        await context.outputs.finalizeTurn(startTime: turnStartTime)
    }

    /// Feeds a content delta through the sidecar extractor instead of `StreamingParser`
    /// (structured-output turns emit JSON in `content`; `<think>` tag-scraping doesn't apply,
    /// but structured `delta.thinking` still routes through `handleStructuredThinkingDelta`).
    private func handleSidecarContentDelta(
        _ result: LLMStreamChunk,
        extractor: inout SidecarStreamExtractor?,
        context: ChatTurnContext,
        continuation: AsyncThrowingStream<ChatEvent, Error>.Continuation
    ) async {
        guard let delta = result.choices.first?.delta.content else { return }
        guard var unwrapped = extractor else { return }
        let outputs = unwrapped.consume(delta)
        extractor = unwrapped
        for output in outputs {
            await routeSidecarOutput(output, context: context, continuation: continuation)
        }
    }

    private func routeSidecarOutput(
        _ output: SidecarStreamExtractor.Output,
        context: ChatTurnContext,
        continuation: AsyncThrowingStream<ChatEvent, Error>.Continuation
    ) async {
        switch output {
        case let .responseDelta(text):
            await context.outputs.appendResponse(text)
            continuation.yield(.generation(text))
        case let .sidecarDelta(delta):
            continuation.yield(.sidecar(delta))
        case let .completed(results):
            await context.outputs.setSidecarResults(results)
            continuation.yield(.sidecarsCompleted(results))
        }
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

    /// Routes a provider-emitted structured reasoning delta (`LLMStreamDelta.thinking`) directly
    /// into `TurnOutputs.appendThinking`, bypassing the `...` tag-scraping parser.
    ///
    /// Precedence / double-counting safety: when a provider emits reasoning as a distinct
    /// structured field, that text arrives on `delta.thinking` (not `delta.content`), so the
    /// tag-scraping parser running on `content` in `handleContentDelta` never sees it — the two
    /// paths are disjoint by construction. For models that instead emit inline ` ... ` text,
    /// `delta.thinking` is `nil` and the parser fallback still classifies it. A model emitting
    /// reasoning through BOTH channels would double-count; in practice structured-reasoning
    /// models put reasoning only in the structured field, so `content` carries no tags.
    private func handleStructuredThinkingDelta(
        _ result: LLMStreamChunk,
        context: ChatTurnContext,
        continuation: AsyncThrowingStream<ChatEvent, Error>.Continuation
    ) async {
        guard let thinking = result.choices.first?.delta.thinking, !thinking.isEmpty else { return }
        await context.outputs.appendThinking(thinking)
        continuation.yield(.thinking(thinking))
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
