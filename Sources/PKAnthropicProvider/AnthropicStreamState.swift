import Foundation
import PKContracts

// MARK: - Stream state

/// Accumulates cross-event state while mapping the Anthropic event stream to `LLMStreamChunk`s.
///
/// Tool-use inputs stream as `input_json_delta.partial_json` fragments scoped to a content
/// block `index`; this state assigns each tool_use block an ordinal (the `LLMToolCallDelta.index`)
/// so downstream accumulation reassembles arguments exactly like the OpenAI-family adapters.
struct AnthropicStreamState {
    let fallbackModel: String
    private(set) var messageID = ""
    private(set) var model: String
    private var inputTokens: Int?
    private var cachedTokens: Int?
    private var toolOrdinalByBlockIndex: [Int: Int] = [:]
    private var nextToolOrdinal = 0

    init(fallbackModel: String) {
        self.fallbackModel = fallbackModel
        model = fallbackModel
    }

    mutating func consume(_ event: AnthropicStreamEvent) -> LLMStreamChunk? {
        switch event.type {
        case "message_start":
            if let message = event.message {
                messageID = message.id
                model = message.model
                inputTokens = message.usage?.inputTokens
                cachedTokens = message.usage?.cacheReadInputTokens
            }
            return nil
        case "content_block_start":
            guard let block = event.contentBlock, block.type == "tool_use",
                  let blockIndex = event.index else { return nil }
            let ordinal = nextToolOrdinal
            nextToolOrdinal += 1
            toolOrdinalByBlockIndex[blockIndex] = ordinal
            return makeChunk(delta: LLMStreamDelta(
                role: .assistant,
                toolCalls: [LLMToolCallDelta(
                    index: ordinal,
                    id: block.id,
                    function: LLMToolCallDeltaFunction(name: block.name, arguments: "")
                )]
            ))
        case "content_block_delta":
            guard let delta = event.delta else { return nil }
            switch delta.type {
            case "text_delta":
                guard let text = delta.text, !text.isEmpty else { return nil }
                return makeChunk(delta: LLMStreamDelta(role: .assistant, content: text))
            case "thinking_delta":
                guard let thinking = delta.thinking, !thinking.isEmpty else { return nil }
                return makeChunk(delta: LLMStreamDelta(role: .assistant, reasoning: thinking))
            case "input_json_delta":
                guard let partial = delta.partialJson, !partial.isEmpty,
                      let blockIndex = event.index,
                      let ordinal = toolOrdinalByBlockIndex[blockIndex] else { return nil }
                return makeChunk(delta: LLMStreamDelta(
                    role: .assistant,
                    toolCalls: [LLMToolCallDelta(
                        index: ordinal,
                        function: LLMToolCallDeltaFunction(arguments: partial)
                    )]
                ))
            default:
                // signature_delta and future delta kinds carry nothing we map.
                return nil
            }
        case "message_delta":
            let stopReason = event.delta?.stopReason.map(mapAnthropicStopReason) ?? .stop
            let outputTokens = event.usage?.outputTokens
            let usage = LLMTokenUsage(
                promptTokens: inputTokens,
                completionTokens: outputTokens,
                totalTokens: (inputTokens ?? 0) + (outputTokens ?? 0),
                promptTokensDetails: cachedTokens.map { .init(cachedTokens: $0) }
            )
            return makeChunk(
                delta: LLMStreamDelta(role: .assistant),
                finishReason: stopReason.wireValue,
                usage: usage
            )
        default:
            // content_block_stop, message_stop, ping: nothing to map.
            return nil
        }
    }

    private func makeChunk(
        delta: LLMStreamDelta,
        finishReason: String? = nil,
        usage: LLMTokenUsage? = nil
    ) -> LLMStreamChunk {
        LLMStreamChunk(
            id: messageID.isEmpty ? UUID().uuidString : messageID,
            model: model,
            choices: [LLMStreamChoice(index: 0, delta: delta, finishReason: finishReason)],
            usage: usage
        )
    }
}
