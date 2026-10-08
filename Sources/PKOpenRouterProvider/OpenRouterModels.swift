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
