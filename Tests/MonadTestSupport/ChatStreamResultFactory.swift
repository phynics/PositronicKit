import Foundation
import OpenAI

#if DEBUG

    /// Typed representation of a tool call for use in mock LLM responses.
    public struct MockToolCall: Sendable {
        public let id: String
        public let name: String
        public let arguments: String

        public init(id: String, name: String, arguments: String = "{}") {
            self.id = id
            self.name = name
            self.arguments = arguments
        }
    }

    /// Centralizes construction of `ChatStreamResult` from JSON dictionaries.
    ///
    /// The OpenAI library's `ChatStreamResult` only has `init(from: Decoder)`,
    /// so we must go through JSON. This factory keeps the fragile JSON shape
    /// in one place instead of spreading it across MockLLMClient and test files.
    public enum ChatStreamResultFactory {
        /// Build a text content chunk.
        public static func textChunk(
            _ content: String,
            finishReason: String? = nil
        ) -> ChatStreamResult {
            decode(
                delta: ["role": "assistant", "content": content],
                finishReason: finishReason
            )
        }

        /// Build a tool call chunk.
        public static func toolCallChunk(
            calls: [MockToolCall],
            content: String? = nil
        ) -> ChatStreamResult {
            let toolCalls = calls.enumerated().map { index, call in
                [
                    "index": index,
                    "id": call.id,
                    "type": "function",
                    "function": ["name": call.name, "arguments": call.arguments]
                ] as [String: Any]
            }
            var delta: [String: Any] = ["role": "assistant", "tool_calls": toolCalls]
            if let content { delta["content"] = content }
            return decode(delta: delta, finishReason: "tool_calls")
        }

        /// Build a tool call chunk from raw dictionaries (backward-compatible bridge).
        public static func toolCallChunk(
            rawCalls: [[String: Any]],
            content: String? = nil
        ) -> ChatStreamResult {
            var delta: [String: Any] = ["role": "assistant", "tool_calls": rawCalls]
            if let content { delta["content"] = content }
            return decode(delta: delta, finishReason: "tool_calls")
        }

        // MARK: - Private

        private static func decode(delta: [String: Any], finishReason: String?) -> ChatStreamResult {
            let json: [String: Any] = [
                "id": "mock",
                "object": "chat.completion.chunk",
                "created": Int(Date().timeIntervalSince1970),
                "model": "mock-model",
                "choices": [
                    [
                        "index": 0,
                        "delta": delta,
                        "finish_reason": finishReason as Any
                    ]
                ]
            ]
            // These force-unwraps are safe — we control the JSON shape.
            // swiftlint:disable:next force_try
            let data = try! JSONSerialization.data(withJSONObject: json)
            // swiftlint:disable:next force_try
            return try! JSONDecoder().decode(ChatStreamResult.self, from: data)
        }
    }

#endif
