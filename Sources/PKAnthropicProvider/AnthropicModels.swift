import Foundation
import struct JSONSchema.Schema
import Logging
import PKContracts
import PKUtilities

// MARK: - Request payload

struct AnthropicChatRequest: Encodable {
    let model: String
    /// Required by the Messages API (unlike the OpenAI family, where it is optional).
    /// Defaulted by the client when `GenerationParameters.maxTokens` is absent.
    let maxTokens: Int
    /// The Messages API accepts `system` as a string or a block array. The adapter always sends
    /// an array so a cache breakpoint can mark the last stable or semi-stable block (#277/#279).
    let system: [AnthropicSystemBlock]?
    let messages: [AnthropicMessage]
    let tools: [AnthropicTool]?
    let toolChoice: AnthropicToolChoice?
    let temperature: Double?
    let topP: Double?
    let stream: Bool

    enum CodingKeys: String, CodingKey {
        case model, system, messages, tools, temperature, stream
        case maxTokens = "max_tokens"
        case toolChoice = "tool_choice"
        case topP = "top_p"
    }
}

/// One provider-neutral system message rendered as an Anthropic system text block.
///
/// A cache breakpoint can attach ``PromptCacheControl`` to the last stable or semi-stable block.
struct AnthropicSystemBlock: Encodable, Equatable {
    let type = "text"
    let text: String
    var cacheControl: PromptCacheControl?

    enum CodingKeys: String, CodingKey {
        case type, text
        case cacheControl = "cache_control"
    }

    init(text: String, cacheControl: PromptCacheControl? = nil) {
        self.text = text
        self.cacheControl = cacheControl
    }
}

/// Anthropic prompt-cache translation: model minimums, the breakpoint plan, and tool markers.
enum AnthropicPromptCache {
    /// The Messages API honors at most four `cache_control` breakpoints per request.
    static let maxBreakpoints = 4

    /// The minimum cacheable prefix for a model, in tokens.
    ///
    /// Anthropic's documented minimums range from 512 to 4,096 tokens across the model family.
    /// The adapter maps the current families conservatively: Haiku models require 2,048 tokens;
    /// every other Claude model requires 1,024. A breakpoint below the minimum is dropped so a
    /// limited slot is not wasted on a prefix the provider will not cache.
    static func minimumPrefixTokens(for model: String) -> Int {
        PromptCacheProviderDefaults.anthropicMinimumPrefixTokens(for: model)
    }

    /// Plans the breakpoints an Anthropic request should carry.
    static func plan(_ directive: PromptCacheDirective, model: String) -> PromptCachePlan {
        PromptCachePlanner.plan(
            directive,
            maxBreakpoints: maxBreakpoints,
            minimumPrefixTokens: minimumPrefixTokens(for: model)
        )
    }

    /// Converts the tool definitions and marks the last one when tools form the reusable prefix.
    ///
    /// A `stableSystem` breakpoint already covers tools because Anthropic orders tools before
    /// system. Only a `tools` breakpoint (emitted when there is no stable system tier) marks the
    /// last tool definition.
    static func markedTools(_ tools: [LLMToolDefinition]?, plan: PromptCachePlan?) -> [AnthropicTool]? {
        guard let tools, !tools.isEmpty else { return nil }
        let converted = tools.map { AnthropicTool($0) }
        guard plan?.breakpoints.contains(where: { $0.tier == .tools && $0.messageIndex == nil }) == true,
              let marker = plan.map({ PromptCacheControl.marker(for: $0.retention) })
        else { return converted }
        var marked = converted
        marked[marked.count - 1].cacheControl = marker
        return marked
    }
}

/// Builds provider-neutral prompt-token details from Anthropic's cache read/write fields.
///
/// Anthropic reports cache writes both as a total (`cache_creation_input_tokens`) and as a
/// per-retention split (`cache_creation.ephemeral_5m_input_tokens` / `ephemeral_1h_input_tokens`).
/// The total is preferred for `cacheWriteTokens`; when only the split is present, the sum is used.
func makeAnthropicPromptDetails(
    cachedTokens: Int?,
    cacheWriteTokens: Int?,
    ephemeral5m: Int?,
    ephemeral1h: Int?
) -> LLMTokenUsagePromptDetails? {
    var breakdown: [PromptCacheDirective.Retention: Int] = [:]
    if let ephemeral5m { breakdown[.short] = ephemeral5m }
    if let ephemeral1h { breakdown[.extended] = ephemeral1h }
    let resolvedWrite = cacheWriteTokens ?? (breakdown.isEmpty ? nil : breakdown.values.reduce(0, +))
    guard cachedTokens != nil || resolvedWrite != nil else { return nil }
    return LLMTokenUsagePromptDetails(
        cachedTokens: cachedTokens,
        cacheWriteTokens: resolvedWrite,
        cacheWriteBreakdown: breakdown.isEmpty ? nil : breakdown
    )
}

struct AnthropicChatResponse: Decodable {
    struct ContentBlock: Decodable {
        let type: String
        let text: String?
        let thinking: String?
        let id: String?
        let name: String?
        let input: AnyCodable?
    }

    struct Usage: Decodable {
        let inputTokens: Int?
        let outputTokens: Int?
        let cacheReadInputTokens: Int?
        let cacheCreationInputTokens: Int?
        let cacheCreation: CacheCreation?

        struct CacheCreation: Decodable {
            let ephemeral5mInputTokens: Int?
            let ephemeral1hInputTokens: Int?

            enum CodingKeys: String, CodingKey {
                case ephemeral5mInputTokens = "ephemeral_5m_input_tokens"
                case ephemeral1hInputTokens = "ephemeral_1h_input_tokens"
            }
        }

        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
            case cacheReadInputTokens = "cache_read_input_tokens"
            case cacheCreationInputTokens = "cache_creation_input_tokens"
            case cacheCreation = "cache_creation"
        }

        var promptDetails: LLMTokenUsagePromptDetails? {
            makeAnthropicPromptDetails(
                cachedTokens: cacheReadInputTokens,
                cacheWriteTokens: cacheCreationInputTokens,
                ephemeral5m: cacheCreation?.ephemeral5mInputTokens,
                ephemeral1h: cacheCreation?.ephemeral1hInputTokens
            )
        }
    }

    let id: String
    let model: String
    let content: [ContentBlock]
    let stopReason: String?
    let usage: Usage?

    enum CodingKeys: String, CodingKey {
        case id, model, content, usage
        case stopReason = "stop_reason"
    }
}

struct AnthropicMessage: Encodable, Equatable {
    let role: String
    var content: [AnthropicContentBlock]
}

/// One Anthropic message content block plus an optional cache breakpoint marker.
///
/// A struct (not an enum) so the same block payload can carry `cache_control` when a breakpoint
/// lands on it. The static constructors keep the previous enum-shorthand call sites unchanged.
struct AnthropicContentBlock: Encodable, Equatable {
    enum Payload: Equatable {
        case text(String)
        case image(mediaType: String, data: Data)
        /// `input` is a JSON object on the wire, not a string like the OpenAI-family
        /// `function.arguments`.
        case toolUse(id: String, name: String, input: AnyCodable)
        case toolResult(toolUseID: String, content: String)
    }

    var payload: Payload
    var cacheControl: PromptCacheControl?

    init(payload: Payload, cacheControl: PromptCacheControl? = nil) {
        self.payload = payload
        self.cacheControl = cacheControl
    }

    static func text(_ text: String) -> AnthropicContentBlock {
        AnthropicContentBlock(payload: .text(text))
    }

    static func image(mediaType: String, data: Data) -> AnthropicContentBlock {
        AnthropicContentBlock(payload: .image(mediaType: mediaType, data: data))
    }

    static func toolUse(id: String, name: String, input: AnyCodable) -> AnthropicContentBlock {
        AnthropicContentBlock(payload: .toolUse(id: id, name: name, input: input))
    }

    static func toolResult(toolUseID: String, content: String) -> AnthropicContentBlock {
        AnthropicContentBlock(payload: .toolResult(toolUseID: toolUseID, content: content))
    }

    private enum CodingKeys: String, CodingKey {
        case type, text, id, name, input, content, source
        case toolUseID = "tool_use_id"
        case cacheControl = "cache_control"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch payload {
        case let .text(text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case let .image(mediaType, data):
            try container.encode("image", forKey: .type)
            try container.encode(
                AnthropicImageSource(mediaType: mediaType, data: data.base64EncodedString()),
                forKey: .source
            )
        case let .toolUse(id, name, input):
            try container.encode("tool_use", forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(name, forKey: .name)
            try container.encode(input, forKey: .input)
        case let .toolResult(toolUseID, content):
            try container.encode("tool_result", forKey: .type)
            try container.encode(toolUseID, forKey: .toolUseID)
            try container.encode(content, forKey: .content)
        }
        if let cacheControl {
            try container.encode(cacheControl, forKey: .cacheControl)
        }
    }
}

private struct AnthropicImageSource: Encodable, Equatable {
    let type = "base64"
    let mediaType: String
    let data: String

    enum CodingKeys: String, CodingKey {
        case type, data
        case mediaType = "media_type"
    }
}

struct AnthropicTool: Encodable {
    let name: String
    let description: String?
    let inputSchema: Schema
    var cacheControl: PromptCacheControl?

    enum CodingKeys: String, CodingKey {
        case name, description
        case inputSchema = "input_schema"
        case cacheControl = "cache_control"
    }

    init(_ tool: LLMToolDefinition, cacheControl: PromptCacheControl? = nil) {
        name = tool.name
        description = tool.description
        inputSchema = tool.parameters ?? makeEmptyObjectSchema()
        self.cacheControl = cacheControl
    }
}

enum AnthropicToolChoice: Encodable {
    case auto
    case tool(String)

    private enum CodingKeys: String, CodingKey {
        case type, name
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .auto:
            try container.encode("auto", forKey: .type)
        case let .tool(name):
            try container.encode("tool", forKey: .type)
            try container.encode(name, forKey: .name)
        }
    }
}

// MARK: - Message conversion

enum AnthropicMessageConversion {
    /// Converts transport-neutral messages into the Messages API shape.
    ///
    /// - `system`/`developer` roles are hoisted into the top-level `system` parameter (the
    ///   Messages API rejects system-role entries inside `messages`).
    /// - Assistant tool calls become `tool_use` content blocks; tool-role results become
    ///   user-role `tool_result` blocks, preserving id pairing (PKINT-002).
    /// - Consecutive same-role messages are merged into one message with multiple content
    ///   blocks, since the Messages API requires alternating user/assistant turns.
    /// - `LLMMessage.reasoning` is intentionally NOT echoed: Anthropic thinking blocks carry a
    ///   provider-issued cryptographic signature that PKRuntime does not persist, and
    ///   unsigned thinking blocks are rejected by the API.
    static func convert(
        messages: [LLMMessage],
        logger: Logger,
        promptCache: PromptCachePlan? = nil
    ) throws -> (system: [AnthropicSystemBlock], messages: [AnthropicMessage]) {
        try validateLLMMessageHistory(messages)

        let marker = promptCache.map { PromptCacheControl.marker(for: $0.retention) }
        var systemBreakpoints: [Int: PromptCacheBreakpoint.Tier] = [:]
        var messageBreakpoints: Set<Int> = []
        if let promptCache {
            for breakpoint in promptCache.breakpoints {
                guard let messageIndex = breakpoint.messageIndex else { continue }
                switch breakpoint.tier {
                case .stableSystem, .semiStableSystem:
                    systemBreakpoints[messageIndex] = breakpoint.tier
                case .tools, .history, .toolLoop:
                    messageBreakpoints.insert(messageIndex)
                }
            }
        }

        var systemBlocks: [AnthropicSystemBlock] = []
        var converted: [AnthropicMessage] = []
        // System content that appears after history (the volatile per-Turn tier) cannot ride in
        // the top-level `system` parameter without landing before history on the wire. Collect it
        // and prepend it to the next user message as a `<turn_context>` text block, matching the
        // runtime's documented Anthropic volatile placement (#277).
        var volatileContextParts: [String] = []
        var sawNonSystemMessage = false

        func append(role: String, blocks: [AnthropicContentBlock]) {
            guard !blocks.isEmpty else { return }
            if var last = converted.last, last.role == role {
                last.content.append(contentsOf: blocks)
                converted[converted.count - 1] = last
            } else {
                converted.append(AnthropicMessage(role: role, content: blocks))
            }
        }

        /// Marks the last block of the message at `index` when a breakpoint closes that tier.
        func marked(_ blocks: [AnthropicContentBlock], at index: Int) -> [AnthropicContentBlock] {
            guard messageBreakpoints.contains(index), let marker, !blocks.isEmpty else { return blocks }
            var result = blocks
            result[result.count - 1].cacheControl = marker
            return result
        }

        for (index, message) in messages.enumerated() {
            if message.role != .system, message.role != .developer {
                sawNonSystemMessage = true
            }
            switch message.role {
            case .system, .developer:
                guard message.messageContent.isTextOnly else {
                    throw MultimodalContentError.unsupportedContentLayout(provider: .anthropic)
                }
                guard !message.content.isEmpty else { continue }
                if sawNonSystemMessage {
                    volatileContextParts.append(message.content)
                } else {
                    systemBlocks.append(AnthropicSystemBlock(
                        text: message.content,
                        cacheControl: systemBreakpoints[index] == nil ? nil : marker
                    ))
                }
            case .user:
                var blocks = try message.messageContent.parts.map { part -> AnthropicContentBlock in
                    switch part {
                    case let .text(text):
                        return .text(text)
                    case let .image(image):
                        return .image(mediaType: image.mediaType, data: image.data)
                    case .audio:
                        throw MultimodalContentError.missingCapability(.audioInput)
                    }
                }
                if !volatileContextParts.isEmpty {
                    let joined = volatileContextParts.joined(separator: "\n\n")
                    volatileContextParts.removeAll()
                    blocks.insert(.text("<turn_context>\n\(joined)\n</turn_context>"), at: 0)
                }
                append(role: "user", blocks: marked(blocks, at: index))
            case .assistant:
                guard !message.messageContent.parts.contains(where: {
                    if case .image = $0 { return true }
                    return false
                }) else {
                    throw MultimodalContentError.unsupportedContentLayout(provider: .anthropic)
                }
                var blocks: [AnthropicContentBlock] = []
                if !message.content.isEmpty {
                    blocks.append(.text(message.content))
                } else if let transcript = message.messageContent.parts.compactMap({ part -> String? in
                    guard case let .audio(audio) = part else { return nil }
                    return audio.transcript
                }).first {
                    blocks.append(.text(transcript))
                }
                for call in message.toolCalls ?? [] {
                    let input: AnyCodable
                    if let data = call.arguments.data(using: .utf8),
                       let parsed = try? JSONDecoder().decode(AnyCodable.self, from: data)
                    {
                        input = parsed
                    } else {
                        logger.warning(
                            "Anthropic tool_use input for call \(call.id) (\(call.name)) is not valid JSON; sending an empty object instead."
                        )
                        input = .dictionary([:])
                    }
                    blocks.append(.toolUse(id: call.id, name: call.name, input: input))
                }
                append(role: "assistant", blocks: marked(blocks, at: index))
            case .tool:
                guard message.messageContent.isTextOnly else {
                    throw MultimodalContentError.unsupportedContentLayout(provider: .anthropic)
                }
                guard let toolCallID = message.toolCallID, !toolCallID.isEmpty else {
                    throw LLMMessageValidationError.missingToolCallID
                }
                append(
                    role: "user",
                    blocks: marked([.toolResult(toolUseID: toolCallID, content: message.content)], at: index)
                )
            }
        }

        if !volatileContextParts.isEmpty {
            logger.debug(
                "Anthropic volatile context followed no user message; it was dropped instead of moving ahead of history."
            )
        }
        return (systemBlocks, converted)
    }
}

// MARK: - Streaming events

/// One decoded Messages API SSE event. The Anthropic stream is event-based
/// (`message_start` / `content_block_start` / `content_block_delta` / `content_block_stop` /
/// `message_delta` / `message_stop`), a materially different shape from the OpenAI-family
/// per-chunk deltas, so it gets its own decoding path before mapping to `LLMStreamChunk`.
struct AnthropicStreamEvent: Decodable {
    struct MessageStart: Decodable {
        let id: String
        let model: String
        let usage: Usage?
    }

    struct ContentBlockStart: Decodable {
        let type: String
        let id: String?
        let name: String?
    }

    struct Delta: Decodable {
        let type: String?
        let text: String?
        let partialJson: String?
        let thinking: String?
        let stopReason: String?
        let stopSequence: String?
    }

    struct Usage: Decodable {
        let inputTokens: Int?
        let outputTokens: Int?
        let cacheReadInputTokens: Int?
        let cacheCreationInputTokens: Int?
        let cacheCreation: CacheCreation?

        struct CacheCreation: Decodable {
            let ephemeral5mInputTokens: Int?
            let ephemeral1hInputTokens: Int?
        }

        var promptDetails: LLMTokenUsagePromptDetails? {
            makeAnthropicPromptDetails(
                cachedTokens: cacheReadInputTokens,
                cacheWriteTokens: cacheCreationInputTokens,
                ephemeral5m: cacheCreation?.ephemeral5mInputTokens,
                ephemeral1h: cacheCreation?.ephemeral1hInputTokens
            )
        }
    }

    struct ErrorBody: Decodable {
        let type: String?
        let message: String?
    }

    let type: String
    let message: MessageStart?
    let index: Int?
    let contentBlock: ContentBlockStart?
    let delta: Delta?
    let usage: Usage?
    let error: ErrorBody?
}

/// Maps an Anthropic `stop_reason` onto the shared `FinishReason` vocabulary (PKR-13).
func mapAnthropicStopReason(_ stopReason: String) -> FinishReason {
    switch stopReason {
    case "end_turn", "stop_sequence":
        return .stop
    case "max_tokens":
        return .length
    case "tool_use":
        return .toolCalls
    case "refusal":
        return .contentFilter
    default:
        return .other(stopReason)
    }
}

// MARK: - Models listing

struct AnthropicModelsResponse: Decodable {
    struct Model: Decodable {
        let id: String
    }

    let data: [Model]
}
