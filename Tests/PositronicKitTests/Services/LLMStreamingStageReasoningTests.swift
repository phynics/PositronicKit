import Foundation
import Logging
import PKShared
import PKTestSupport
import Testing
@testable import PositronicKit

/// End-to-end coverage for STAB-7: structured reasoning deltas (provider-emitted distinct
/// `thinking` field) routed into `TurnOutputs.fullThinking` via `LLMStreamingStage`, plus the
/// inline-tag fallback regression.
@Suite("LLMStreamingStage structured reasoning routing")
struct LLMStreamingStageReasoningTests {
    private let logger = Logger(label: "test")

    /// A stubbed stream emitting structured `thinking` deltas (no inline ` ... ` tags) must
    /// accumulate reasoning into `TurnOutputs.fullThinking` and emit `.thinking` events, and the
    /// answer text into `fullResponse` — without any tag-scraping.
    @Test("Structured thinking deltas accumulate into TurnOutputs.fullThinking")
    func structuredThinkingDeltasAccumulate() async throws {
        let service = MockLLMService()
        service.mockClient.nextRawStreamChunks = [[
            ChatStreamResultFactory.thinkingChunk("reasoned "),
            ChatStreamResultFactory.thinkingChunk("more"),
            ChatStreamResultFactory.textChunk("the answer", finishReason: "stop"),
        ]]

        let context = makeContext()
        let stage = LLMStreamingStage(llmService: service, logger: logger, streamTimeout: 5)

        let stream = try await stage.process(context)
        let events = try await stream.collect()

        let thinkingEvents: [String] = events.compactMap { event in
            if case .delta(.thinking(let text)) = event { return text } else { return nil }
        }
        #expect(thinkingEvents == ["reasoned ", "more"])
        #expect(await context.outputs.fullThinking == "reasoned more")
        #expect(await context.outputs.fullResponse == "the answer")
    }

    /// Fallback regression: a stream emitting inline ` ... ` text inside `content` (no
    /// structured `thinking` field) must still classify reasoning via the `StreamingParser`
    /// tag-scraping path. Existing behavior is preserved.
    @Test("Inline thinking tags in content still capture thinking via the parser fallback")
    func inlineThinkingTagsFallback() async throws {
        // Built via concatenation so the literal tag bytes (`<` + "think" + ">", etc.) are
        // guaranteed present in the source regardless of editor rendering.
        let openTag = "<" + "think" + ">"
        let closeTag = "<" + "/" + "think" + ">"
        let taggedContent = openTag + "thinking here" + closeTag + "answer"

        let service = MockLLMService()
        service.mockClient.nextRawStreamChunks = [[
            ChatStreamResultFactory.textChunk(taggedContent, finishReason: "stop"),
        ]]

        let context = makeContext()
        let stage = LLMStreamingStage(llmService: service, logger: logger, streamTimeout: 5)

        let stream = try await stage.process(context)
        _ = try await stream.collect()

        #expect(await context.outputs.fullThinking == "thinking here")
        #expect(await context.outputs.fullResponse == "answer")
    }

    /// Structured reasoning must not double-count when a model emits reasoning only via the
    /// structured field: `content` carries no tags, so the parser contributes zero thinking and
    /// only the structured path populates `fullThinking`.
    @Test("Structured reasoning does not double-count via the tag-scraping fallback")
    func noDoubleCountingForStructuredReasoning() async throws {
        let service = MockLLMService()
        // Structured reasoning arrives on `thinking`; `content` carries plain answer text with
        // no tags — the parser path must contribute nothing to fullThinking.
        service.mockClient.nextRawStreamChunks = [[
            ChatStreamResultFactory.thinkingChunk("only-once", content: nil),
            ChatStreamResultFactory.textChunk("plain answer", finishReason: "stop"),
        ]]

        let context = makeContext()
        let stage = LLMStreamingStage(llmService: service, logger: logger, streamTimeout: 5)

        let stream = try await stage.process(context)
        _ = try await stream.collect()

        #expect(await context.outputs.fullThinking == "only-once")
        #expect(await context.outputs.fullResponse == "plain answer")
    }

    // MARK: - Helpers

    private func makeContext() -> ChatTurnContext {
        ChatTurnContext(
            timelineId: UUID(),
            agentInstanceId: nil,
            modelName: "test-model",
            maxTurns: 5,
            systemInstructions: nil,
            availableTools: [],
            contextData: ContextData(),
            remoteDepth: 0,
            currentMessages: [LLMMessage(role: .user, content: "hi")],
            turnCount: 1,
            outputs: TurnOutputs()
        )
    }
}
