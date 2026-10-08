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

    package enum CodingKeys: String, CodingKey {
        case model, input, tools, text, reasoning, include, store, stream, seed
        case toolChoice = "tool_choice"
        case maxOutputTokens = "max_output_tokens"
        case temperature
        case topP = "top_p"
        case presencePenalty = "presence_penalty"
        case frequencyPenalty = "frequency_penalty"
    }
}

package enum ResponsesInputItem: Encodable {
    case message(role: String, content: [ResponsesContentPart])
    case functionCallOutput(callId: String, output: String)
    case reasoningEncrypted(id: String, encryptedContent: String)

    package func encode(to encoder: Encoder) throws {
        switch self {
        case let .message(role, content):
            var c = encoder.container(keyedBy: MsgKeys.self)
            try c.encode("message", forKey: .type)
            try c.encode(role, forKey: .role)
            try c.encode(content, forKey: .content)
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
    package var toolNames: [Int: String] = [:]
    package var toolCallIds: [Int: String] = [:]
    package var sawContent = false
    package init() {}
    package var hasYielded: Bool { sawContent }
    package var shouldRetryAfterError: Bool { !sawContent }
}

package enum ResponsesEvents {
    package static func chunk(forEventType type: String, payload: Data, model: String, responseID: String, audioFormat: AudioFormat? = nil, accumulator: inout ResponsesStreamAccumulator, usage: LLMTokenUsage? = nil) -> LLMStreamChunk? {
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
        case "response.function_call_arguments.delta":
            let idx = (json["output_index"] as? Int) ?? 0
            if let d = json["delta"] as? String { accumulator.toolArgs[idx, default: ""] += d }
            if let id = json["item_id"] as? String { accumulator.toolCallIds[idx] = id }
            if let name = json["name"] as? String { accumulator.toolNames[idx] = name }
            accumulator.sawContent = true
            return LLMStreamChunk(id: responseID, model: model, choices: [.init(index: 0, delta: .init(role: .assistant, toolCalls: [.init(index: idx, id: accumulator.toolCallIds[idx], function: .init(name: accumulator.toolNames[idx], arguments: json["delta"] as? String))]), finishReason: nil)], usage: nil)
        case "response.completed":
            accumulator.sawContent = true
            var usageOut = usage
            if let u = json["usage"] as? [String: Any] {
                usageOut = LLMTokenUsage(promptTokens: u["input_tokens"] as? Int, completionTokens: u["output_tokens"] as? Int, totalTokens: u["total_tokens"] as? Int, promptTokensDetails: .init(cachedTokens: (u["input_tokens_details"] as? [String: Any])?["cached_tokens"] as? Int))
            }
            return LLMStreamChunk(id: responseID, model: model, choices: [.init(index: 0, delta: .init(role: .assistant), finishReason: FinishReason.stop.wireValue)], usage: usageOut)
        default: return nil
        }
    }
}
