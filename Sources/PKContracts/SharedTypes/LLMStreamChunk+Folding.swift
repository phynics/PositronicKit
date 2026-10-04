import Foundation

/// Folds streamed chunks into the request-response representation: one terminal chunk.
public extension LLMStreamChunk {
    /// Combines streamed deltas into one chunk, or returns `nil` when there are no chunks.
    ///
    /// Response identity and model use the last non-empty value. Content, reasoning, audio
    /// data, audio transcripts, tool-call names, and indexed tool-call arguments are concatenated
    /// in arrival order. Choices and tool calls retain first-seen index order; tool-call IDs use
    /// the first non-`nil` value. Finish reason and usage use the last non-`nil` value.
    static func folding(_ chunks: [LLMStreamChunk]) -> LLMStreamChunk? {
        guard !chunks.isEmpty else { return nil }

        struct ToolCallParts {
            var id: String?
            var name = ""
            var arguments = ""
        }

        struct ChoiceParts {
            var content = ""
            var reasoning = ""
            var audioData = Data()
            var audioTranscript = ""
            var lastAudio: LLMAudioDelta?
            var toolCallOrder: [Int] = []
            var toolCalls: [Int: ToolCallParts] = [:]
            var finishReason: String?
        }

        var id = ""
        var model = ""
        var choiceOrder: [Int] = []
        var choices: [Int: ChoiceParts] = [:]
        var usage: LLMTokenUsage?

        for chunk in chunks {
            if !chunk.id.isEmpty { id = chunk.id }
            if !chunk.model.isEmpty { model = chunk.model }
            if let chunkUsage = chunk.usage { usage = chunkUsage }

            for choice in chunk.choices {
                if choices[choice.index] == nil {
                    choiceOrder.append(choice.index)
                    choices[choice.index] = ChoiceParts()
                }
                guard var parts = choices[choice.index] else { continue }

                if let reason = choice.finishReason { parts.finishReason = reason }
                if let text = choice.delta.content { parts.content += text }
                if let text = choice.delta.reasoning { parts.reasoning += text }
                if let audio = choice.delta.audio {
                    parts.audioData.append(audio.data)
                    if let transcript = audio.transcript { parts.audioTranscript += transcript }
                    parts.lastAudio = audio
                }
                for delta in choice.delta.toolCalls ?? [] {
                    guard let index = delta.index else { continue }
                    if parts.toolCalls[index] == nil {
                        parts.toolCallOrder.append(index)
                        parts.toolCalls[index] = ToolCallParts()
                    }
                    if var call = parts.toolCalls[index] {
                        if call.id == nil, let id = delta.id { call.id = id }
                        if let name = delta.function?.name { call.name += name }
                        if let arguments = delta.function?.arguments { call.arguments += arguments }
                        parts.toolCalls[index] = call
                    }
                }
                choices[choice.index] = parts
            }
        }

        let foldedChoices = (choiceOrder.isEmpty ? [0] : choiceOrder).map { index in
            let parts = choices[index] ?? ChoiceParts()
            let foldedToolCalls = parts.toolCallOrder.map { toolCallIndex in
                let call = parts.toolCalls[toolCallIndex]!
                return LLMToolCallDelta(
                    index: toolCallIndex,
                    id: call.id,
                    function: LLMToolCallDeltaFunction(
                        name: call.name.isEmpty ? nil : call.name,
                        arguments: call.arguments.isEmpty ? nil : call.arguments
                    )
                )
            }
            let audio: LLMAudioDelta? = parts.lastAudio.map {
                LLMAudioDelta(
                    data: parts.audioData,
                    format: $0.format,
                    transcript: parts.audioTranscript.isEmpty ? nil : parts.audioTranscript,
                    continuation: $0.continuation
                )
            }
            return LLMStreamChoice(
                index: index,
                delta: LLMStreamDelta(
                    role: .assistant,
                    content: parts.content.isEmpty ? nil : parts.content,
                    reasoning: parts.reasoning.isEmpty ? nil : parts.reasoning,
                    audio: audio,
                    toolCalls: foldedToolCalls.isEmpty ? nil : foldedToolCalls
                ),
                finishReason: parts.finishReason
            )
        }
        return LLMStreamChunk(
            id: id,
            model: model,
            choices: foldedChoices,
            usage: usage
        )
    }
}
