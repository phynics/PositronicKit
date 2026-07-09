import Foundation
import PKShared
import PositronicKit

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

    /// Centralizes construction of neutral stream chunks for tests.
    public enum ChatStreamResultFactory {
        /// Build a text content chunk.
        public static func textChunk(
            _ content: String,
            finishReason: String? = nil
        ) -> LLMStreamChunk {
            LLMStreamChunk(
                id: "mock",
                model: "mock-model",
                choices: [LLMStreamChoice(
                    index: 0,
                    delta: LLMStreamDelta(role: .assistant, content: content),
                    finishReason: finishReason
                )]
            )
        }

        /// Build a structured reasoning/thinking chunk (provider-emitted distinct field, not
        /// inline ` ... ` tags). Used to exercise the STAB-7 structured-reasoning routing path.
        public static func thinkingChunk(
            _ thinking: String,
            content: String? = nil,
            finishReason: String? = nil
        ) -> LLMStreamChunk {
            LLMStreamChunk(
                id: "mock",
                model: "mock-model",
                choices: [LLMStreamChoice(
                    index: 0,
                    delta: LLMStreamDelta(role: .assistant, content: content, reasoning: thinking),
                    finishReason: finishReason
                )]
            )
        }

        /// Build a tool call chunk.
        public static func toolCallChunk(
            calls: [MockToolCall],
            content: String? = nil
        ) -> LLMStreamChunk {
            let toolCalls = calls.enumerated().map { index, call in
                LLMToolCallDelta(
                    index: index,
                    id: call.id,
                    function: LLMToolCallDeltaFunction(name: call.name, arguments: call.arguments)
                )
            }
            return LLMStreamChunk(
                id: "mock",
                model: "mock-model",
                choices: [LLMStreamChoice(
                    index: 0,
                    delta: LLMStreamDelta(role: .assistant, content: content, toolCalls: toolCalls),
                    finishReason: "tool_calls"
                )]
            )
        }

        /// Build a tool call chunk from raw dictionaries (backward-compatible bridge).
        public static func toolCallChunk(
            rawCalls: [[String: Any]],
            content: String? = nil
        ) -> LLMStreamChunk {
            let toolCalls = rawCalls.enumerated().map { index, call in
                let function = call["function"] as? [String: Any]
                return LLMToolCallDelta(
                    index: (call["index"] as? Int) ?? index,
                    id: call["id"] as? String,
                    function: LLMToolCallDeltaFunction(
                        name: function?["name"] as? String,
                        arguments: function?["arguments"] as? String
                    )
                )
            }
            return LLMStreamChunk(
                id: "mock",
                model: "mock-model",
                choices: [LLMStreamChoice(
                    index: 0,
                    delta: LLMStreamDelta(role: .assistant, content: content, toolCalls: toolCalls),
                    finishReason: "tool_calls"
                )]
            )
        }
    }

#endif
