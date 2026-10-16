import Foundation
import struct JSONSchema.Schema
import PKContracts
import PKUtilities

// OpenRouter is a thin preset over the shared ChatCompletions wire.
// Public type names stay so the change is not breaking.
package typealias OpenRouterChatRequest = ChatCompletionsChatRequest
package typealias OpenRouterChatResponse = ChatCompletionsChatResponse
package typealias OpenRouterMessage = ChatCompletionsMessage
package typealias OpenRouterMessageContent = ChatCompletionsMessageContent
package typealias OpenRouterContentPart = ChatCompletionsContentPart
package typealias OpenRouterTool = ChatCompletionsTool
package typealias OpenRouterToolCall = ChatCompletionsToolCall
package typealias OpenRouterToolCallFunction = ChatCompletionsToolCallFunction
package typealias OpenRouterToolDefinition = ChatCompletionsToolDefinition
package typealias OpenRouterToolChoice = ChatCompletionsToolChoice
package typealias OpenRouterResponseFormat = ChatCompletionsResponseFormat
package typealias OpenRouterResponseSchema = ChatCompletionsResponseSchema
package typealias OpenRouterStreamOptions = ChatCompletionsStreamOptions
package typealias OpenRouterStreamChunk = ChatCompletionsStreamChunk
package typealias OpenRouterUsage = ChatCompletionsUsage
package typealias OpenRouterAssistantAudio = ChatCompletionsAssistantAudio

package struct OpenRouterModelsResponse: Codable {
    package struct Model: Codable { package let id: String }
    package let data: [Model]
}

/// OpenRouter prompt-cache translation.
///
/// OpenRouter relies on the upstream provider's caching. For `anthropic/*` routes it passes
/// Anthropic-style `cache_control` markers through content blocks; for every other route the
/// `session_id` routing key is the only hint and the upstream caches automatically (#279).
enum OpenRouterPromptCache {
    /// Anthropic honors at most four explicit breakpoints per request.
    static let maxBreakpoints = 4

    static func isAnthropicRouted(model: String) -> Bool {
        model.lowercased().hasPrefix("anthropic/")
    }

    static func plan(_ directive: PromptCacheDirective, model: String) -> PromptCachePlan {
        PromptCachePlanner.plan(
            directive,
            maxBreakpoints: maxBreakpoints,
            minimumPrefixTokens: PromptCacheProviderDefaults.anthropicMinimumPrefixTokens(for: model)
        )
    }

    /// Attaches a `cache_control` marker to the last content block of each marked message.
    ///
    /// The `tools` tier has no message index and OpenRouter's function-tool wire has no
    /// cache-control field, so it is skipped; the system/history/tool-loop block markers are
    /// enough for Anthropic's prefix caching.
    static func apply(_ plan: PromptCachePlan, to messages: [ChatCompletionsMessage]) -> [ChatCompletionsMessage] {
        let marker = PromptCacheControl.marker(for: plan.retention)
        var result = messages
        for breakpoint in plan.breakpoints {
            guard let index = breakpoint.messageIndex, result.indices.contains(index) else { continue }
            result[index].applyCacheControl(marker)
        }
        return result
    }
}
