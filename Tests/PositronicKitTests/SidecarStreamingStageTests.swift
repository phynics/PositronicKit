import Foundation
import JSONSchemaBuilder
import Logging
import PKShared
import PKUtilities
import PKTestSupport
@testable import PositronicKit
import Testing

@Suite("LLMStreamingStage sidecar routing")
struct SidecarStreamingStageTests {
    private let logger = Logger(label: "test")

    private var directives: [SidecarDirective] {
        [
            .init(name: "title", instruction: "t", schema: JSONString().definition(), streaming: .buffered),
            .init(name: "tone", instruction: "n", schema: JSONString().definition(), streaming: .buffered),
        ]
    }

    /// A sidecar turn must emit `.generation` events carrying only the extracted `response`
    /// text (never raw JSON), route directive fields through `.sidecar`/`.sidecarsCompleted`,
    /// and accumulate `TurnOutputs.fullResponse` as response text only.
    @Test("Sidecar turn emits extracted response text and routes directive results")
    func sidecarTurnRoutesResponseAndDirectives() async throws {
        let service = MockLLMService()
        service.mockClient.nextRawStreamChunks = [[
            ChatStreamResultFactory.textChunk(#"{"response": "Hel"#),
            ChatStreamResultFactory.textChunk(#"lo", "title": "Greeting", "tone": "warm"}"#, finishReason: "stop"),
        ]]

        let context = makeContext(sidecars: directives)
        let stage = LLMStreamingStage(llmService: service, logger: logger, streamTimeout: 5)

        let stream = try await stage.process(context)
        let events = try await stream.collect()

        let generationText = events.compactMap(\.textContent).joined()
        #expect(generationText == "Hello")
        #expect(!generationText.contains("{"))

        let sidecarDeltas = events.compactMap(\.sidecarDelta)
        #expect(sidecarDeltas.contains { $0.name == "title" && $0.partialText == "Greeting" && $0.isFinal })
        #expect(sidecarDeltas.contains { $0.name == "tone" && $0.partialText == "warm" && $0.isFinal })

        let completed = events.compactMap(\.sidecarResults).flatMap { $0 }
        #expect(completed.contains(SidecarResult(name: "title", outcome: .value(AnyCodable("Greeting")))))
        #expect(completed.contains(SidecarResult(name: "tone", outcome: .value(AnyCodable("warm")))))

        #expect(await context.outputs.fullResponse == "Hello")
    }

    /// Pinning test (SDC-5 no-op guarantee): a turn with `sidecars: []` must behave
    /// byte-identically to today's plain-text streaming for the same chunks.
    @Test("Turn with no sidecars streams identically to plain content")
    func noSidecarsTurnBehavesLikeToday() async throws {
        let service = MockLLMService()
        service.mockClient.nextRawStreamChunks = [[
            ChatStreamResultFactory.textChunk("Hello ", finishReason: nil),
            ChatStreamResultFactory.textChunk("there", finishReason: "stop"),
        ]]

        let context = makeContext(sidecars: [])
        let stage = LLMStreamingStage(llmService: service, logger: logger, streamTimeout: 5)

        let stream = try await stage.process(context)
        let events = try await stream.collect()

        let generationText = events.compactMap(\.textContent).joined()
        #expect(generationText == "Hello there")
        #expect(events.compactMap(\.sidecarDelta).isEmpty)
        #expect(events.compactMap(\.sidecarResults).isEmpty)
        #expect(await context.outputs.fullResponse == "Hello there")
    }

    /// Structured `thinking` deltas still pass through unchanged on sidecar turns (the
    /// extractor only intercepts `content`, not the distinct `thinking` field).
    @Test("Structured thinking deltas pass through unchanged on sidecar turns")
    func thinkingDeltasUnaffectedOnSidecarTurns() async throws {
        let service = MockLLMService()
        service.mockClient.nextRawStreamChunks = [[
            ChatStreamResultFactory.thinkingChunk("reasoning", content: nil),
            ChatStreamResultFactory.textChunk(#"{"response": "ok", "title": "T", "tone": "flat"}"#, finishReason: "stop"),
        ]]

        let context = makeContext(sidecars: directives)
        let stage = LLMStreamingStage(llmService: service, logger: logger, streamTimeout: 5)

        let stream = try await stage.process(context)
        let events = try await stream.collect()

        #expect(events.compactMap(\.reasoningContent) == ["reasoning"])
        #expect(await context.outputs.fullThinking == "reasoning")
        #expect(await context.outputs.fullResponse == "ok")
    }

    // MARK: - Helpers

    private func makeContext(sidecars: [SidecarDirective]) -> ChatTurnContext {
        ChatTurnContext(
            threadID: UUID(),
            agentInstanceId: nil,
            modelName: "test-model",
            maxTurns: 5,
            systemInstructions: nil,
            availableTools: [],
            contextData: ContextData(),
            remoteDepth: 0,
            sidecars: sidecars,
            currentMessages: [LLMMessage(role: .user, content: "hi")],
            turnCount: 1,
            outputs: TurnOutputs()
        )
    }
}
