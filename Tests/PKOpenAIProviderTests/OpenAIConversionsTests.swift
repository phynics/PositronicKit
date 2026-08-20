import Foundation
import struct JSONSchema.Schema
import OpenAI
@testable import PKOpenAIProvider
import PKContracts
import PKUtilities
import PositronicKit
import Testing

/// Comprehensive conversion coverage for `OpenAIConversions.swift`.
///
/// These are the pure, load-bearing mapping functions between the provider-neutral
/// `LLMMessage`/`LLMToolDefinition`/`LLMToolChoice`/`LLMResponseFormat` types and the
/// OpenAI SDK's wire types. They were previously exercised only transitively through
/// `chatStream` integration tests, leaving most branches (system, assistant, developer
/// roles; tool-choice; response-format; schema conversion; finish-reason and role
/// mapping) unverified.
@Suite("OpenAI conversions")
struct OpenAIConversionsTests {

    // MARK: - LLMMessage.toOpenAIMessageParam

    @Test("system role maps to .system param with textContent")
    func systemRoleConversion() throws {
        let message = LLMMessage(role: .system, content: "You are helpful.", name: "sys")
        let param = try message.toOpenAIMessageParam()

        guard case let .system(systemMsg) = param else {
            Issue.record("Expected .system param"); return
        }
        if case let .textContent(text) = systemMsg.content {
            #expect(text == "You are helpful.")
        } else {
            Issue.record("Expected .textContent")
        }
        #expect(systemMsg.name == "sys")
    }

    @Test("user role maps to .user param with string content")
    func userRoleConversion() throws {
        let message = LLMMessage(role: .user, content: "Hello!", name: "alice")
        let param = try message.toOpenAIMessageParam()

        guard case let .user(userMsg) = param else {
            Issue.record("Expected .user param"); return
        }
        if case let .string(text) = userMsg.content {
            #expect(text == "Hello!")
        } else {
            Issue.record("Expected .string content")
        }
        #expect(userMsg.name == "alice")
    }

    @Test("ordered user media maps to OpenAI content parts")
    func orderedMultimodalUserConversion() throws {
        let message = LLMMessage(role: .user, content: MessageContent(parts: [
            .text("first"),
            .image(ImageContent(data: Data([0x01, 0x02]), mediaType: "image/png", detail: .high)),
            .audio(AudioContent(data: Data([0x03, 0x04]), format: .wav)),
            .text("last"),
        ]))

        let encoded = try JSONEncoder().encode(try message.toOpenAIMessageParam())
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let content = try #require(object["content"] as? [[String: Any]])

        #expect(content.compactMap { $0["type"] as? String } == ["text", "image_url", "input_audio", "text"])
        #expect((content[1]["image_url"] as? [String: Any])?["url"] as? String == "data:image/png;base64,AQI=")
        #expect((content[2]["input_audio"] as? [String: Any])?["data"] as? String == "AwQ=")
        #expect((content[2]["input_audio"] as? [String: Any])?["format"] as? String == "wav")
    }

    @Test("assistant role with tool calls maps to .assistant param with toolCalls")
    func assistantRoleWithToolCalls() throws {
        let message = LLMMessage(
            role: .assistant,
            content: "Let me check.",
            toolCalls: [
                LLMToolCall(id: "call_1", name: "get_weather", arguments: #"{"city":"Berlin"}"#),
            ]
        )
        let param = try message.toOpenAIMessageParam()

        guard case let .assistant(assistantMsg) = param else {
            Issue.record("Expected .assistant param"); return
        }
        if case let .textContent(text) = assistantMsg.content {
            #expect(text == "Let me check.")
        } else {
            Issue.record("Expected .textContent")
        }
        let toolCalls = try #require(assistantMsg.toolCalls)
        #expect(toolCalls.count == 1)
        #expect(toolCalls.first?.id == "call_1")
        #expect(toolCalls.first?.function.name == "get_weather")
        #expect(toolCalls.first?.function.arguments == #"{"city":"Berlin"}"#)
    }

    @Test("assistant role without tool calls maps to .assistant param with nil toolCalls")
    func assistantRoleWithoutToolCalls() throws {
        let message = LLMMessage(role: .assistant, content: "Hi there.")
        let param = try message.toOpenAIMessageParam()

        guard case let .assistant(assistantMsg) = param else {
            Issue.record("Expected .assistant param"); return
        }
        if case let .textContent(text) = assistantMsg.content {
            #expect(text == "Hi there.")
        } else {
            Issue.record("Expected .textContent")
        }
        #expect(assistantMsg.toolCalls == nil)
    }

    @Test("developer role maps to .developer param")
    func developerRoleConversion() throws {
        let message = LLMMessage(role: .developer, content: "Dev instructions.", name: "dev")
        let param = try message.toOpenAIMessageParam()

        guard case let .developer(devMsg) = param else {
            Issue.record("Expected .developer param"); return
        }
        if case let .textContent(text) = devMsg.content {
            #expect(text == "Dev instructions.")
        } else {
            Issue.record("Expected .textContent")
        }
        #expect(devMsg.name == "dev")
    }

    @Test("tool role with toolCallID maps to .tool param without warning")
    func toolRoleWithID() throws {
        let message = LLMMessage(role: .tool, content: "result", toolCallID: "call_1")
        let param = try message.toOpenAIMessageParam()

        guard case let .tool(toolMsg) = param else {
            Issue.record("Expected .tool param"); return
        }
        #expect(toolMsg.toolCallId == "call_1")
        if case let .textContent(text) = toolMsg.content {
            #expect(text == "result")
        } else {
            Issue.record("Expected .textContent")
        }
    }

    // MARK: - LLMToolChoice.toOpenAIToolChoice

    @Test("toolChoice .auto maps to .auto")
    func toolChoiceAuto() {
        let choice = LLMToolChoice.auto
        let param = choice.toOpenAIToolChoice()
        guard case .auto = param else {
            Issue.record("Expected .auto"); return
        }
    }

    @Test("toolChoice .function maps to .function(name)")
    func toolChoiceFunction() {
        let choice = LLMToolChoice.function("get_weather")
        let param = choice.toOpenAIToolChoice()
        guard case let .function(name) = param else {
            Issue.record("Expected .function"); return
        }
        #expect(name == "get_weather")
    }

    // MARK: - LLMResponseFormat.toOpenAIResponseFormat

    @Test("responseFormat .text maps to .text")
    func responseFormatText() {
        let format = LLMResponseFormat.text
        let param = format.toOpenAIResponseFormat()
        guard case .text = param else {
            Issue.record("Expected .text"); return
        }
    }

    @Test("responseFormat .jsonObject maps to .jsonObject")
    func responseFormatJsonObject() {
        let format = LLMResponseFormat.jsonObject
        let param = format.toOpenAIResponseFormat()
        guard case .jsonObject = param else {
            Issue.record("Expected .jsonObject"); return
        }
    }

    @Test("responseFormat .jsonSchema encodes name, description, and strict")
    func responseFormatJsonSchema() throws {
        let schema = LLMResponseSchema(
            name: "weather_result",
            description: "Weather output",
            schema: nil,
            strict: true
        )
        let format = LLMResponseFormat.jsonSchema(schema)
        let param = format.toOpenAIResponseFormat()

        // StructuredOutputConfigurationOptions fields are internal, so verify via encoding.
        let encoded = try JSONEncoder().encode(param)
        let json = try #require(String(data: encoded, encoding: .utf8))
        #expect(json.contains("weather_result"))
        #expect(json.contains("Weather output"))
        #expect(json.contains("\"strict\":true"))
    }

    @Test("responseFormat .jsonSchema with a concrete schema converts the schema")
    func responseFormatJsonSchemaWithSchema() throws {
        let rawSchema = try Schema(instance: #"{"type":"object","properties":{"city":{"type":"string"}},"required":["city"]}"#)
        let responseSchema = LLMResponseSchema(
            name: "weather",
            description: nil,
            schema: rawSchema,
            strict: nil
        )
        let format = LLMResponseFormat.jsonSchema(responseSchema)
        let param = format.toOpenAIResponseFormat()

        let encoded = try JSONEncoder().encode(param)
        let json = try #require(String(data: encoded, encoding: .utf8))
        #expect(json.contains("weather"))
        #expect(json.contains("city"))
    }

    // MARK: - LLMToolDefinition.toOpenAIToolParam

    @Test("tool definition maps to ChatCompletionToolParam with name, description, and strict")
    func toolDefinitionConversion() {
        let tool = LLMToolDefinition(
            name: "get_weather",
            description: "Get the weather for a city",
            parameters: nil,
            strict: true
        )
        let param = tool.toOpenAIToolParam()
        #expect(param.function.name == "get_weather")
        #expect(param.function.description == "Get the weather for a city")
        #expect(param.function.strict == true)
        #expect(param.function.parameters == nil)
    }

    @Test("tool definition with a schema converts parameters")
    func toolDefinitionWithSchema() throws {
        let rawSchema = try Schema(instance: #"{"type":"object","properties":{"city":{"type":"string"}},"required":["city"]}"#)
        let tool = LLMToolDefinition(
            name: "get_weather",
            description: "Get weather",
            parameters: rawSchema,
            strict: false
        )
        let param = tool.toOpenAIToolParam()
        #expect(param.function.name == "get_weather")
        #expect(param.function.parameters != nil)
        #expect(param.function.strict == false)
    }

    // MARK: - ChatStreamResult.toLLMStreamChunk

    @Test("stream chunk with tool call deltas maps toolCalls")
    func streamChunkWithToolCallDeltas() throws {
        let json = #"""
        {
          "id": "chatcmpl-1",
          "object": "chat.completion.chunk",
          "created": 1710000000,
          "model": "gpt-4o",
          "choices": [
            {
              "index": 0,
              "delta": {
                "role": "assistant",
                "tool_calls": [
                  {
                    "index": 0,
                    "id": "call_1",
                    "type": "function",
                    "function": {
                      "name": "get_weather",
                      "arguments": "{\"city\":\"Berlin\"}"
                    }
                  }
                ]
              },
              "finish_reason": null
            }
          ]
        }
        """#
        let result = try JSONDecoder().decode(ChatStreamResult.self, from: Data(json.utf8))
        let chunk = result.toLLMStreamChunk()

        let toolCalls = try #require(chunk.choices.first?.delta.toolCalls)
        #expect(toolCalls.count == 1)
        #expect(toolCalls.first?.index == 0)
        #expect(toolCalls.first?.id == "call_1")
        #expect(toolCalls.first?.function?.name == "get_weather")
        #expect(toolCalls.first?.function?.arguments == #"{"city":"Berlin"}"#)
    }

    @Test("stream chunk with usage maps token counts and cached tokens")
    func streamChunkWithUsage() throws {
        let json = #"""
        {
          "id": "chatcmpl-2",
          "object": "chat.completion.chunk",
          "created": 1710000000,
          "model": "gpt-4o",
          "choices": [
            {
              "index": 0,
              "delta": {"content": "hi"},
              "finish_reason": null
            }
          ],
          "usage": {
            "prompt_tokens": 10,
            "completion_tokens": 5,
            "total_tokens": 15,
            "prompt_tokens_details": {"cached_tokens": 3, "audio_tokens": 0}
          }
        }
        """#
        let result = try JSONDecoder().decode(ChatStreamResult.self, from: Data(json.utf8))
        let chunk = result.toLLMStreamChunk()

        let usage = try #require(chunk.usage)
        #expect(usage.promptTokens == 10)
        #expect(usage.completionTokens == 5)
        #expect(usage.totalTokens == 15)
        #expect(usage.promptTokensDetails?.cachedTokens == 3)
    }

    @Test("stream chunk with usage but no cached tokens details")
    func streamChunkWithUsageNoDetails() throws {
        let json = #"""
        {
          "id": "chatcmpl-3",
          "object": "chat.completion.chunk",
          "created": 1710000000,
          "model": "gpt-4o",
          "choices": [{"index": 0, "delta": {"content": "hi"}, "finish_reason": null}],
          "usage": {"prompt_tokens": 10, "completion_tokens": 5, "total_tokens": 15}
        }
        """#
        let result = try JSONDecoder().decode(ChatStreamResult.self, from: Data(json.utf8))
        let chunk = result.toLLMStreamChunk()

        let usage = try #require(chunk.usage)
        #expect(usage.promptTokensDetails?.cachedTokens == nil)
    }

    @Test("stream chunk maps all finish reasons correctly")
    func finishReasonMapping() throws {
        let finishReasons: [(String, String)] = [
            ("stop", "stop"),
            ("length", "length"),
            ("tool_calls", "tool_calls"),
            ("content_filter", "content_filter"),
            ("function_call", "function_call"),
        ]
        for (wire, expected) in finishReasons {
            let json = """
            {"id":"c","object":"chat.completion.chunk","created":0,"model":"m","choices":[{"index":0,"delta":{"content":"x"},"finish_reason":"\(wire)"}]}
            """
            let result = try JSONDecoder().decode(ChatStreamResult.self, from: Data(json.utf8))
            let chunk = result.toLLMStreamChunk()
            #expect(chunk.choices.first?.finishReason == expected)
        }
    }

    @Test("stream chunk with error finish reason maps to other")
    func errorFinishReasonMapping() throws {
        let json = #"""
        {"id":"c","object":"chat.completion.chunk","created":0,"model":"m","choices":[{"index":0,"delta":{"content":"x"},"finish_reason":"error"}]}
        """#
        let result = try JSONDecoder().decode(ChatStreamResult.self, from: Data(json.utf8))
        let chunk = result.toLLMStreamChunk()
        #expect(chunk.choices.first?.finishReason == "error")
    }

    @Test("stream chunk maps all delta roles correctly")
    func roleMapping() throws {
        let roles: [(String, LLMMessage.Role)] = [
            ("assistant", .assistant),
            ("developer", .developer),
            ("system", .system),
            ("tool", .tool),
            ("user", .user),
        ]
        for (wire, expected) in roles {
            let json = """
            {"id":"c","object":"chat.completion.chunk","created":0,"model":"m","choices":[{"index":0,"delta":{"role":"\(wire)"},"finish_reason":null}]}
            """
            let result = try JSONDecoder().decode(ChatStreamResult.self, from: Data(json.utf8))
            let chunk = result.toLLMStreamChunk()
            #expect(chunk.choices.first?.delta.role == expected)
        }
    }

    // MARK: - ChatResult.toLLMToolCallRecoveryChunk

    @Test("recovery chunk returns nil when choices is empty")
    func recoveryChunkEmptyChoices() throws {
        let json = #"""
        {"id":"c","object":"chat.completion","created":0,"model":"m","choices":[]}
        """#
        let result = try JSONDecoder().decode(ChatResult.self, from: Data(json.utf8))
        #expect(result.toLLMToolCallRecoveryChunk() == nil)
    }

    @Test("recovery chunk returns nil when finish reason is not tool_calls")
    func recoveryChunkNonToolCallsFinishReason() throws {
        let json = #"""
        {"id":"c","object":"chat.completion","created":0,"model":"m","choices":[{"index":0,"finish_reason":"stop","message":{"role":"assistant","content":"hi"}}]}
        """#
        let result = try JSONDecoder().decode(ChatResult.self, from: Data(json.utf8))
        #expect(result.toLLMToolCallRecoveryChunk() == nil)
    }

    @Test("recovery chunk returns nil when tool_calls is empty")
    func recoveryChunkEmptyToolCalls() throws {
        let json = #"""
        {"id":"c","object":"chat.completion","created":0,"model":"m","choices":[{"index":0,"finish_reason":"tool_calls","message":{"role":"assistant","content":null,"tool_calls":[]}}]}
        """#
        let result = try JSONDecoder().decode(ChatResult.self, from: Data(json.utf8))
        #expect(result.toLLMToolCallRecoveryChunk() == nil)
    }

    @Test("recovery chunk returns nil when tool_calls is nil")
    func recoveryChunkNilToolCalls() throws {
        let json = #"""
        {"id":"c","object":"chat.completion","created":0,"model":"m","choices":[{"index":0,"finish_reason":"tool_calls","message":{"role":"assistant","content":null}}]}
        """#
        let result = try JSONDecoder().decode(ChatResult.self, from: Data(json.utf8))
        #expect(result.toLLMToolCallRecoveryChunk() == nil)
    }

    @Test("recovery chunk with usage maps token counts")
    func recoveryChunkWithUsage() throws {
        let json = #"""
        {
          "id": "chatcmpl-123",
          "object": "chat.completion",
          "created": 1710000000,
          "model": "gpt-4o",
          "choices": [
            {
              "index": 0,
              "finish_reason": "tool_calls",
              "message": {
                "role": "assistant",
                "content": null,
                "tool_calls": [
                  {"id":"call_1","type":"function","function":{"name":"f","arguments":"{}"}}
                ]
              }
            }
          ],
          "usage": {"prompt_tokens": 10, "completion_tokens": 5, "total_tokens": 15, "prompt_tokens_details": {"cached_tokens": 2, "audio_tokens": 0}}
        }
        """#
        let result = try JSONDecoder().decode(ChatResult.self, from: Data(json.utf8))
        let chunk = try #require(result.toLLMToolCallRecoveryChunk())
        let usage = try #require(chunk.usage)
        #expect(usage.promptTokens == 10)
        #expect(usage.completionTokens == 5)
        #expect(usage.totalTokens == 15)
        #expect(usage.promptTokensDetails?.cachedTokens == 2)
    }

    @Test("recovery chunk maps message content and reasoning")
    func recoveryChunkContentAndReasoning() throws {
        let json = #"""
        {
          "id": "chatcmpl-123",
          "object": "chat.completion",
          "created": 1710000000,
          "model": "gpt-4o",
          "choices": [
            {
              "index": 0,
              "finish_reason": "tool_calls",
              "message": {
                "role": "assistant",
                "content": "Thinking about it",
                "reasoning": "Step by step",
                "tool_calls": [
                  {"id":"call_1","type":"function","function":{"name":"f","arguments":"{}"}}
                ]
              }
            }
          ]
        }
        """#
        let result = try JSONDecoder().decode(ChatResult.self, from: Data(json.utf8))
        let chunk = try #require(result.toLLMToolCallRecoveryChunk())
        #expect(chunk.choices.first?.delta.content == "Thinking about it")
        #expect(chunk.choices.first?.delta.reasoning == "Step by step")
        #expect(chunk.choices.first?.delta.role == .assistant)
    }

    @Test("recovery chunk with multiple tool calls assigns sequential indices")
    func recoveryChunkMultipleToolCalls() throws {
        let json = #"""
        {
          "id": "chatcmpl-123",
          "object": "chat.completion",
          "created": 1710000000,
          "model": "gpt-4o",
          "choices": [
            {
              "index": 0,
              "finish_reason": "tool_calls",
              "message": {
                "role": "assistant",
                "content": null,
                "tool_calls": [
                  {"id":"call_1","type":"function","function":{"name":"f1","arguments":"{}"}},
                  {"id":"call_2","type":"function","function":{"name":"f2","arguments":"{}"}}
                ]
              }
            }
          ]
        }
        """#
        let result = try JSONDecoder().decode(ChatResult.self, from: Data(json.utf8))
        let chunk = try #require(result.toLLMToolCallRecoveryChunk())
        let toolCalls = try #require(chunk.choices.first?.delta.toolCalls)
        #expect(toolCalls.count == 2)
        #expect(toolCalls[0].index == 0)
        #expect(toolCalls[1].index == 1)
    }
}
