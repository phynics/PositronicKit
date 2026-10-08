import Foundation
import PKContracts
import PKUtilities

// OpenAI-specific mappings on top of the shared ChatCompletions wire.
// Audio continuation provider is .openAI; reasoning is omitted on Chat Completions history.

package extension LLMToolDefinition {
    func toOpenAIToolParam() -> ChatCompletionsTool { ChatCompletionsTool(self) }
}

package extension LLMMessage {
    func toOpenAIMessageParam() throws -> ChatCompletionsMessage {
        if role == .tool { try validateLLMMessageHistory([self]) }
        // Validate audio formats early (WAV/MP3 only for OpenAI).
        for part in messageContent.parts {
            if case let .audio(audio) = part, audio.format != .wav, audio.format != .mp3 {
                throw MultimodalContentError.unsupportedAudioFormat(audio.format, provider: .openAI)
            }
        }
        return ChatCompletionsMessage(self, provider: .openAI)
    }
}

package extension LLMToolChoice {
    func toOpenAIToolChoice() -> ChatCompletionsToolChoice {
        ChatCompletionsWire.mapToolChoice(self, tools: [.init(name: "x", description: nil, parameters: nil)]) ?? ChatCompletionsToolChoice.auto
    }
}

package extension LLMResponseFormat {
    func toOpenAIResponseFormat() -> ChatCompletionsResponseFormat? {
        ChatCompletionsWire.mapResponseFormat(self)
    }
}

package func mapOpenAIFinishReason(_ wireValue: String) -> FinishReason {
    FinishReason(wireValue: wireValue)
}
