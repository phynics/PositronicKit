import Foundation
import PKContracts
import PKUtilities

/// Maps `FoundationModelsSessionEvent`s onto the transport-neutral `LLMStreamChunk` contract
/// (PKPOST-003; PKINT-001 conformance for the synthesized event sequence). Pure and
/// framework-independent — exercised directly in tests against scripted event sequences, with
/// no dependency on `FoundationModels` or a live session.
enum FoundationModelsStreamMapper {
    /// Assigns each distinct tool-call id an ordinal, matching how the OpenAI-family and
    /// Anthropic adapters assign `LLMToolCallDelta.index` (accumulation in `LLMStreamingStage`
    /// keys on ordinal, not id).
    struct State {
        private var ordinalByToolCallID: [String: Int] = [:]
        private var nextOrdinal = 0

        mutating func ordinal(for toolCallID: String) -> Int {
            if let existing = ordinalByToolCallID[toolCallID] { return existing }
            let ordinal = nextOrdinal
            nextOrdinal += 1
            ordinalByToolCallID[toolCallID] = ordinal
            return ordinal
        }
    }

    /// Maps a single event to zero-or-one `LLMStreamChunk`. `toolOutput` produces no chunk of
    /// its own — PositronicKit's tool-execution stage owns the tool-result message, and
    /// FoundationModels already executed the tool internally by the time this event arrives
    /// (unlike the HTTP adapters, where the caller executes tools after a `tool_calls` finish).
    static func map(
        _ event: FoundationModelsSessionEvent,
        model: String,
        messageID: String,
        state: inout State
    ) -> LLMStreamChunk? {
        switch event {
        case let .textDelta(text):
            guard !text.isEmpty else { return nil }
            return makeChunk(
                id: messageID,
                model: model,
                delta: LLMStreamDelta(role: .assistant, content: text)
            )

        case let .toolCall(id, name, argumentsJSON):
            let ordinal = state.ordinal(for: id)
            return makeChunk(
                id: messageID,
                model: model,
                delta: LLMStreamDelta(
                    role: .assistant,
                    toolCalls: [LLMToolCallDelta(
                        index: ordinal,
                        id: id,
                        function: LLMToolCallDeltaFunction(name: name, arguments: argumentsJSON)
                    )]
                )
            )

        case .toolOutput:
            return nil

        case let .finished(reason):
            return makeChunk(
                id: messageID,
                model: model,
                delta: LLMStreamDelta(role: .assistant),
                finishReason: reason.wireValue
            )
        }
    }

    private static func makeChunk(
        id: String,
        model: String,
        delta: LLMStreamDelta,
        finishReason: String? = nil
    ) -> LLMStreamChunk {
        LLMStreamChunk(
            id: id,
            model: model,
            choices: [LLMStreamChoice(index: 0, delta: delta, finishReason: finishReason)]
        )
    }
}
