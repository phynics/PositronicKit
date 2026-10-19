import Foundation
import struct JSONSchema.Schema
import PKContracts
import PKUtilities

// MARK: - Responses API wire (stateless; Timeline owns history)

package struct ResponsesRequest: Encodable {
    package var model: String
    package var input: [ResponsesInputItem]
    package var tools: [ResponsesTool]?
    package var toolChoice: ResponsesToolChoice?
    package var text: ResponsesTextConfig?
    package var reasoning: ResponsesReasoningConfig?
    package var include: [String]?
    package var store: Bool
    package var stream: Bool
    package var maxOutputTokens: Int?
    package var temperature: Double?
    package var topP: Double?
    package var seed: Int?
    package var presencePenalty: Double?
    package var frequencyPenalty: Double?
    /// OpenAI's routing key for automatic prefix caching, when the runtime derived one.
    package var promptCacheKey: String?
    /// OpenAI's retention window (`in_memory` or `24h`); omitted when the model does not support it.
    package var promptCacheRetention: String?

    package enum CodingKeys: String, CodingKey {
        case model, input, tools, text, reasoning, include, store, stream, seed
        case toolChoice = "tool_choice"
        case maxOutputTokens = "max_output_tokens"
        case temperature
        case topP = "top_p"
        case presencePenalty = "presence_penalty"
        case frequencyPenalty = "frequency_penalty"
        case promptCacheKey = "prompt_cache_key"
        case promptCacheRetention = "prompt_cache_retention"
    }
}

package enum ResponsesInputItem: Encodable {
    case message(role: String, content: [ResponsesContentPart])
    case functionCall(callId: String, name: String, arguments: String)
    case functionCallOutput(callId: String, output: String)
    case reasoningEncrypted(id: String, encryptedContent: String)

    package func encode(to encoder: Encoder) throws {
        switch self {
        case let .message(role, content):
            var c = encoder.container(keyedBy: MsgKeys.self)
            try c.encode("message", forKey: .type)
            try c.encode(role, forKey: .role)
            try c.encode(content, forKey: .content)
        case let .functionCall(callId, name, arguments):
            var c = encoder.container(keyedBy: FunctionCallKeys.self)
            try c.encode("function_call", forKey: .type)
            try c.encode(callId, forKey: .callId)
            try c.encode(name, forKey: .name)
            try c.encode(arguments, forKey: .arguments)
        case let .functionCallOutput(callId, output):
            var c = encoder.container(keyedBy: CallKeys.self)
            try c.encode("function_call_output", forKey: .type)
            try c.encode(callId, forKey: .callId)
            try c.encode(output, forKey: .output)
        case let .reasoningEncrypted(id, encryptedContent):
            var c = encoder.container(keyedBy: ReasoningKeys.self)
            try c.encode("reasoning", forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(encryptedContent, forKey: .encryptedContent)
        }
    }
    private enum MsgKeys: String, CodingKey { case type, role, content }
    private enum FunctionCallKeys: String, CodingKey { case type, name, arguments; case callId = "call_id" }
    private enum CallKeys: String, CodingKey { case type; case callId = "call_id"; case output }
    private enum ReasoningKeys: String, CodingKey { case type, id; case encryptedContent = "encrypted_content" }
}

package enum ResponsesContentPart: Encodable {
    case text(String)
    case image(data: Data, mediaType: String, detail: String?)
    case audio(data: Data, format: String)

    package func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        switch self {
        case let .text(t): try c.encode("input_text", forKey: .type); try c.encode(t, forKey: .text)
        case let .image(data, mediaType, detail):
            try c.encode("input_image", forKey: .type)
            try c.encode("data:\(mediaType);base64,\(data.base64EncodedString())", forKey: .imageUrl)
            if let detail { try c.encode(detail, forKey: .detail) }
        case let .audio(data, format):
            try c.encode("input_audio", forKey: .type)
            try c.encode(data.base64EncodedString(), forKey: .inputAudio)
            try c.encode(format, forKey: .format)
        }
    }
    private enum K: String, CodingKey { case type, text; case imageUrl = "image_url"; case detail; case inputAudio = "input_audio"; case format }
}

package struct ResponsesTool: Encodable {
    package let type = "function"
    package let name: String
    package let description: String?
    package let parameters: Schema?
    package let strict: Bool?
}

package enum ResponsesToolChoice: Encodable {
    case auto, none, required, function(String)
    package func encode(to encoder: Encoder) throws {
        switch self {
        case .auto: var c = encoder.singleValueContainer(); try c.encode("auto")
        case .none: var c = encoder.singleValueContainer(); try c.encode("none")
        case .required: var c = encoder.singleValueContainer(); try c.encode("required")
        case let .function(name):
            var c = encoder.container(keyedBy: K.self)
            try c.encode("function", forKey: .type); try c.encode(name, forKey: .name)
        }
    }
    private enum K: String, CodingKey { case type, name }
}

package struct ResponsesTextConfig: Encodable {
    package var format: ResponsesTextFormat?
}

package enum ResponsesTextFormat: Encodable {
    case text, jsonObject, jsonSchema(name: String, description: String?, schema: Schema?, strict: Bool?)
    package func encode(to encoder: Encoder) throws {
        switch self {
        case .text: var c = encoder.singleValueContainer(); try c.encode(["type": "text"])
        case .jsonObject: var c = encoder.singleValueContainer(); try c.encode(["type": "json_object"])
        case let .jsonSchema(name, description, schema, strict):
            var c = encoder.container(keyedBy: K.self)
            try c.encode("json_schema", forKey: .type)
            try c.encode(name, forKey: .name)
            if let description { try c.encode(description, forKey: .description) }
            if let schema { try c.encode(schema, forKey: .schema) }
            if let strict { try c.encode(strict, forKey: .strict) }
        }
    }
    private enum K: String, CodingKey { case type, name, description, schema, strict }
}

package struct ResponsesReasoningConfig: Encodable {
    package var effort: String?
    package var summary: String?
}

// MARK: - Responses streaming events -> LLMStreamChunk

package struct ResponsesStreamAccumulator: Sendable {
    package var textDeltas: [String] = []
    package var reasoningDeltas: [String] = []
    package var toolArgs: [Int: String] = [:]
    package var toolItemIds: [Int: String] = [:]
    package var sawContent = false
    /// Whether the Responses stream delivered a valid terminal event
    /// (`response.completed`, `response.incomplete`, `response.failed`, or `error`).
    /// EOF without one is an abnormal stream (issue #369).
    package var sawTerminalEvent = false
    package init() {}
    package var hasYielded: Bool { sawContent }
    package var shouldRetryAfterError: Bool { !sawContent }
}

package enum ResponsesEvents {
    /// Terminal classification of a consumed Responses SSE event (issue #369).
    ///
    /// The Responses wire protocol terminates every stream with exactly one of
    /// `response.completed`, `response.incomplete`, `response.failed`, or a bare `error`
    /// event. `completed` and `incomplete` are valid terminals (the latter records a
    /// non-`.stop` finish reason); `failed` and `error` are provider-reported failures that
    /// must surface as a thrown error instead of a clean EOF.
    package enum Terminal: Sendable, Equatable {
        case completed
        /// Valid terminal; the mapped finish reason (`length`, `content_filter`, or a
        /// provider passthrough) is carried on the terminal chunk.
        case incomplete(FinishReason)
        /// Provider-reported failure; `message` preserves the provider's diagnostics.
        case failed(message: String)
        /// In-band `error` event; `message` preserves the provider's diagnostics.
        case providerError(message: String)
    }

    package static func chunk(forEventType type: String, payload: Data, model: String, responseID: String, audioFormat: AudioFormat? = nil, accumulator: inout ResponsesStreamAccumulator) -> LLMStreamChunk? {
        guard let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { return nil }
        switch type {
        case "response.output_text.delta":
            guard let d = json["delta"] as? String else { return nil }
            accumulator.textDeltas.append(d); accumulator.sawContent = true
            return LLMStreamChunk(id: responseID, model: model, choices: [.init(index: 0, delta: .init(role: .assistant, content: d), finishReason: nil)], usage: nil)
        case "response.reasoning_summary_text.delta":
            guard let d = json["delta"] as? String else { return nil }
            accumulator.reasoningDeltas.append(d); accumulator.sawContent = true
            return LLMStreamChunk(id: responseID, model: model, choices: [.init(index: 0, delta: .init(role: .assistant, content: nil, reasoning: d), finishReason: nil)], usage: nil)
        case "response.output_item.added":
            guard let idx = json["output_index"] as? Int,
                  let item = json["item"] as? [String: Any],
                  item["type"] as? String == "function_call",
                  let itemID = item["id"] as? String,
                  let callID = item["call_id"] as? String,
                  let name = item["name"] as? String
            else { return nil }
            let initialArguments = item["arguments"] as? String ?? ""
            accumulator.toolItemIds[idx] = itemID
            accumulator.toolArgs[idx] = initialArguments
            accumulator.sawContent = true
            return LLMStreamChunk(
                id: responseID,
                model: model,
                choices: [.init(index: 0, delta: .init(role: .assistant, toolCalls: [
                    .init(
                        index: idx,
                        id: callID,
                        function: .init(name: name, arguments: initialArguments.isEmpty ? nil : initialArguments)
                    ),
                ]), finishReason: nil)],
                usage: nil
            )
        case "response.function_call_arguments.delta":
            guard let idx = json["output_index"] as? Int,
                  let delta = json["delta"] as? String
            else { return nil }
            guard let knownItemID = accumulator.toolItemIds[idx] else { return nil }
            if let itemID = json["item_id"] as? String,
               itemID != knownItemID
            {
                return nil
            }
            accumulator.toolArgs[idx, default: ""] += delta
            accumulator.sawContent = true
            return LLMStreamChunk(id: responseID, model: model, choices: [.init(index: 0, delta: .init(role: .assistant, toolCalls: [.init(index: idx, function: .init(arguments: delta))]), finishReason: nil)], usage: nil)
        case "response.function_call_arguments.done":
            guard let idx = json["output_index"] as? Int,
                  let arguments = json["arguments"] as? String
            else { return nil }
            guard let knownItemID = accumulator.toolItemIds[idx] else { return nil }
            if let itemID = json["item_id"] as? String,
               itemID != knownItemID
            {
                return nil
            }
            let streamedArguments = accumulator.toolArgs[idx, default: ""]
            guard arguments.hasPrefix(streamedArguments) else { return nil }
            let missingArguments = String(arguments.dropFirst(streamedArguments.count))
            guard !missingArguments.isEmpty else { return nil }
            accumulator.toolArgs[idx] = arguments
            accumulator.sawContent = true
            return LLMStreamChunk(id: responseID, model: model, choices: [.init(index: 0, delta: .init(role: .assistant, toolCalls: [.init(index: idx, function: .init(arguments: missingArguments))]), finishReason: nil)], usage: nil)
        case "response.completed":
            accumulator.sawContent = true
            return LLMStreamChunk(id: responseID, model: model, choices: [.init(index: 0, delta: .init(role: .assistant), finishReason: FinishReason.stop.wireValue)], usage: parseUsage(from: json))
        case "response.incomplete":
            // A truncation terminal is not a clean stop: record the mapped finish reason
            // (`length` for token/length limits) plus usage on the terminal chunk so the
            // Turn's terminal metadata stays truthful (issue #369).
            accumulator.sawContent = true
            return LLMStreamChunk(id: responseID, model: model, choices: [.init(index: 0, delta: .init(role: .assistant), finishReason: incompleteFinishReason(from: json).wireValue)], usage: parseUsage(from: json))
        default: return nil
        }
    }

    /// Classifies a Responses stream event as a protocol terminal, or `nil` when the event is
    /// not terminal (deltas, `response.in_progress`, `sequence` events, …).
    package static func terminalEvent(forEventType type: String, payload: Data) -> Terminal? {
        switch type {
        case "response.completed":
            return .completed
        case "response.incomplete":
            guard let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
                return .incomplete(.other("incomplete"))
            }
            return .incomplete(incompleteFinishReason(from: json))
        case "response.failed":
            return .failed(message: failureMessage(eventType: type, payload: payload))
        case "error":
            return .providerError(message: failureMessage(eventType: type, payload: payload))
        default:
            return nil
        }
    }

    // MARK: - Terminal payload helpers

    /// Maps an `incomplete_details.reason` onto the shared ``FinishReason`` vocabulary.
    /// Length-family reasons map to `.length`; content filtering to `.contentFilter`;
    /// anything else passes through verbatim as ``FinishReason.other(_:)``.
    private static func incompleteFinishReason(from json: [String: Any]) -> FinishReason {
        // The reason sits on `response.incomplete_details` for the terminal event object,
        // or on `response.response.incomplete_details` when the payload embeds the full
        // response resource.
        let source = (json["response"] as? [String: Any]) ?? json
        guard let details = source["incomplete_details"] as? [String: Any],
              let reason = details["reason"] as? String
        else {
            return .other("incomplete")
        }
        switch reason {
        case "max_output_tokens": return .length
        case "content_filter": return .contentFilter
        default: return .other(reason)
        }
    }

    /// Builds a provider-diagnostic failure message from a `response.failed` or `error`
    /// event payload. Prefers the structured `error.code`/`error.message` fields (the
    /// nested `error` object may live inside the embedded `response` resource); falls back
    /// to the flat `code`/`message` fields on the event payload itself, then to a sanitized
    /// payload snippet so diagnostics are never silently dropped.
    private static func failureMessage(eventType: String, payload: Data) -> String {
        let source = if let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] {
            (json["response"] as? [String: Any]) ?? json
        } else {
            [String: Any]()
        }
        let nestedError = source["error"] as? [String: Any]
        let code = (nestedError?["code"] as? String) ?? (source["code"] as? String)
        let message = (nestedError?["message"] as? String) ?? (source["message"] as? String)
        switch (code, message) {
        case let (code?, message?): return "\(eventType): \(code): \(message)"
        case let (code?, nil): return "\(eventType): \(code)"
        case let (nil, message?): return "\(eventType): \(message)"
        default: break
        }
        return "\(eventType): \(ProviderHTTPFailure.sanitize(String(decoding: payload, as: UTF8.self)))"
    }

    /// Parses `usage` for terminal events, accepting the flat wire shape (usage beside the
    /// event type) and the real `response.completed` shape (usage nested inside the
    /// embedded `response` resource).
    private static func parseUsage(from json: [String: Any]) -> LLMTokenUsage? {
        guard let u = json["usage"] as? [String: Any] ?? (json["response"] as? [String: Any])?["usage"] as? [String: Any] else { return nil }
        let inputDetails = u["input_tokens_details"] as? [String: Any]
        let writeTokens = (u["cache_write_tokens"] as? Int) ?? (inputDetails?["cache_write_tokens"] as? Int)
        let cachedTokens = inputDetails?["cached_tokens"] as? Int
        let details: LLMTokenUsagePromptDetails? = (cachedTokens != nil || writeTokens != nil)
            ? .init(cachedTokens: cachedTokens, cacheWriteTokens: writeTokens)
            : nil
        return LLMTokenUsage(promptTokens: u["input_tokens"] as? Int, completionTokens: u["output_tokens"] as? Int, totalTokens: u["total_tokens"] as? Int, promptTokensDetails: details)
    }
}
