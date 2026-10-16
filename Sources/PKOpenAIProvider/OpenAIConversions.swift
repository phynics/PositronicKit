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

/// OpenAI prompt-cache translation: the retention wire values and the model capability table.
///
/// OpenAI caches prefixes automatically, so the adapter sends a routing key and a retention
/// window but no explicit breakpoints. The GPT-5.6+ `prompt_cache_breakpoint` fields were not
/// confirmed against the official API reference (the only signal was OpenRouter's summary), so
/// this adapter relies on automatic prefix caching rather than sending an unverified field.
package enum OpenAIPromptCache {
    /// OpenAI's in-memory (short) retention wire value.
    package static let shortRetention = "in_memory"
    /// OpenAI's 24-hour (extended) retention wire value.
    package static let extendedRetention = "24h"

    /// Model families known to accept `prompt_cache_retention`.
    ///
    /// Unlisted models omit the field and use the provider default; `prompt_cache_key` is sent
    /// regardless because it is broadly supported.
    private static let retentionModelPrefixes = [
        "gpt-4.1", "gpt-4o", "gpt-5", "o1", "o3", "o4",
    ]

    package static func retention(for directive: PromptCacheDirective?, model: String) -> String? {
        guard let directive, supportsRetention(model: model) else { return nil }
        switch directive.retention {
        case .short: return shortRetention
        case .extended: return extendedRetention
        }
    }

    package static func supportsRetention(model: String) -> Bool {
        let normalized = model.lowercased()
        return retentionModelPrefixes.contains { normalized == $0 || normalized.hasPrefix($0 + "-") }
    }
}
