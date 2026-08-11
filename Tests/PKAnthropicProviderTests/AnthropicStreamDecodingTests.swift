import Foundation
import Logging
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
@testable import PKAnthropicProvider
import PKShared
import PKUtilities
import PKTestSupport
import PositronicKit
import Testing

/// Authored Anthropic Messages API SSE fixtures (PKINT-001 conformance for the synthesized
/// event stream). The Anthropic stream is event-based — a materially different wire shape
/// from the OpenAI-family per-chunk deltas — so it gets its own fixture set here rather than
/// reusing `StreamWireFixtures`.
private enum AnthropicWireFixtures {
    static let messageStart = #"data: {"type":"message_start","message":{"id":"msg_01","model":"claude-sonnet-4-5","usage":{"input_tokens":12,"cache_read_input_tokens":3}}}"#

    static let textBlockStart = #"data: {"type":"content_block_start","index":0,"content_block":{"type":"text"}}"#
    static let textDelta1 = #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"hello "}}"#
    static let textDelta2 = #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"world"}}"#
    static let textBlockStop = #"data: {"type":"content_block_stop","index":0}"#

    static let thinkingBlockStart = #"data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking"}}"#
    static let thinkingDelta = #"data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"pondering"}}"#

    static let toolBlockStart = #"data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_01","name":"lookup_weather"}}"#
    static let toolInputDelta1 = #"data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"city\":"}}"#
    static let toolInputDelta2 = #"data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"\"Berlin\"}"}}"#
    static let toolBlockStop = #"data: {"type":"content_block_stop","index":1}"#

    static let secondToolBlockStart = #"data: {"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"toolu_02","name":"lookup_time"}}"#
    static let secondToolInputDelta = #"data: {"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"{\"tz\":\"CET\"}"}}"#

    static let messageDeltaToolUse = #"data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":5}}"#
    static let messageDeltaEndTurn = #"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":2}}"#
    static let messageStop = #"data: {"type":"message_stop"}"#
    static let ping = #"data: {"type":"ping"}"#

    static let errorEvent = #"data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#
}

private actor AnthropicTestTransport: ProviderHTTPTransport {
    private(set) var requests: [URLRequest] = []
    let lines: [String]
    let statusCode: Int

    init(lines: [String], statusCode: Int = 200) {
        self.lines = lines
        self.statusCode = statusCode
    }

    func lastRequest() -> URLRequest? {
        requests.last
    }

    func requestCount() -> Int {
        requests.count
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        return (Data(lines.joined(separator: "\n").utf8), makeResponse(for: request))
    }

    func lines(for request: URLRequest) async throws -> (AsyncThrowingStream<String, Error>, URLResponse) {
        requests.append(request)
        let lines = self.lines
        return (
            AsyncThrowingStream { continuation in
                for line in lines {
                    continuation.yield(line)
                }
                continuation.finish()
            },
            makeResponse(for: request)
        )
    }

    private func makeResponse(for request: URLRequest) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url ?? URL(string: "https://api.anthropic.com/v1/messages")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "text/event-stream"]
        )!
    }
}

private func makeClient(transport: AnthropicTestTransport, maxRetries: Int = 3) -> AnthropicClient {
    AnthropicClient(
        apiKey: "secret",
        modelName: "claude-sonnet-4-5",
        maxRetries: maxRetries,
        transport: transport
    )
}

@Suite("Anthropic stream decoding conformance")
struct AnthropicStreamDecodingTests {
    @Test("Text deltas, tool_use blocks, stop reason, and usage survive a full event session")
    func fullSessionDecodesToChunks() async throws {
        let transport = AnthropicTestTransport(lines: [
            AnthropicWireFixtures.messageStart,
            AnthropicWireFixtures.ping,
            AnthropicWireFixtures.textBlockStart,
            AnthropicWireFixtures.textDelta1,
            AnthropicWireFixtures.textDelta2,
            AnthropicWireFixtures.textBlockStop,
            AnthropicWireFixtures.toolBlockStart,
            AnthropicWireFixtures.toolInputDelta1,
            AnthropicWireFixtures.toolInputDelta2,
            AnthropicWireFixtures.toolBlockStop,
            AnthropicWireFixtures.messageDeltaToolUse,
            AnthropicWireFixtures.messageStop,
        ])

        let chunks = try await makeClient(transport: transport).chatStream(
            messages: [LLMMessage(role: .user, content: "weather in berlin")],
            tools: nil,
            toolChoice: nil,
            responseFormat: nil,
            generationParameters: nil
        ).collect()

        let text = chunks.compactMap { $0.choices.first?.delta.content }.joined()
        #expect(text == "hello world")

        // tool_use start carries the id + name at the assigned ordinal index…
        let toolStart = try #require(chunks.first { $0.choices.first?.delta.toolCalls?.first?.id != nil })
        let startCall = try #require(toolStart.choices.first?.delta.toolCalls?.first)
        #expect(startCall.id == "toolu_01")
        #expect(startCall.index == 0)
        #expect(startCall.function?.name == "lookup_weather")

        // …and input_json_delta fragments reassemble the full arguments at the same index.
        let fragments = chunks
            .compactMap { $0.choices.first?.delta.toolCalls?.first }
            .filter { $0.index == 0 }
            .compactMap { $0.function?.arguments }
            .joined()
        #expect(fragments == #"{"city":"Berlin"}"#)

        let final = try #require(chunks.first { $0.choices.first?.finishReason != nil })
        #expect(final.choices.first?.finishReason == "tool_calls")
        #expect(final.usage?.promptTokens == 12)
        #expect(final.usage?.completionTokens == 5)
        #expect(final.usage?.totalTokens == 17)
        #expect(final.usage?.promptTokensDetails?.cachedTokens == 3)

        // All chunks carry the wire message id/model from message_start.
        #expect(chunks.allSatisfy { $0.id == "msg_01" })
        #expect(chunks.allSatisfy { $0.model == "claude-sonnet-4-5" })
    }

    @Test("Parallel tool_use blocks map to distinct ordinal indices without cross-contamination")
    func parallelToolBlocksKeepDistinctOrdinals() async throws {
        let transport = AnthropicTestTransport(lines: [
            AnthropicWireFixtures.messageStart,
            AnthropicWireFixtures.toolBlockStart,
            AnthropicWireFixtures.secondToolBlockStart,
            AnthropicWireFixtures.toolInputDelta1,
            AnthropicWireFixtures.secondToolInputDelta,
            AnthropicWireFixtures.toolInputDelta2,
            AnthropicWireFixtures.messageDeltaToolUse,
            AnthropicWireFixtures.messageStop,
        ])

        let chunks = try await makeClient(transport: transport).chatStream(
            messages: [LLMMessage(role: .user, content: "weather and time")],
            tools: nil,
            toolChoice: nil,
            responseFormat: nil,
            generationParameters: nil
        ).collect()

        let calls = chunks.compactMap { $0.choices.first?.delta.toolCalls?.first }
        let firstToolArgs = calls.filter { $0.index == 0 }.compactMap { $0.function?.arguments }.joined()
        let secondToolArgs = calls.filter { $0.index == 1 }.compactMap { $0.function?.arguments }.joined()

        #expect(calls.first { $0.id == "toolu_01" }?.index == 0)
        #expect(calls.first { $0.id == "toolu_02" }?.index == 1)
        #expect(firstToolArgs == #"{"city":"Berlin"}"#)
        #expect(secondToolArgs == #"{"tz":"CET"}"#)
    }

    @Test("thinking_delta events map to the thinking field")
    func thinkingDeltasMapToThinking() async throws {
        let transport = AnthropicTestTransport(lines: [
            AnthropicWireFixtures.messageStart,
            AnthropicWireFixtures.thinkingBlockStart,
            AnthropicWireFixtures.thinkingDelta,
            AnthropicWireFixtures.messageDeltaEndTurn,
            AnthropicWireFixtures.messageStop,
        ])

        let chunks = try await makeClient(transport: transport).chatStream(
            messages: [LLMMessage(role: .user, content: "think about it")],
            tools: nil,
            toolChoice: nil,
            responseFormat: nil,
            generationParameters: nil
        ).collect()

        #expect(chunks.compactMap { $0.choices.first?.delta.reasoning }.joined() == "pondering")
        let final = try #require(chunks.first { $0.choices.first?.finishReason != nil })
        #expect(final.choices.first?.finishReason == "stop")
    }

    @Test("An error stream event surfaces as a thrown, sanitized error")
    func errorEventThrows() async throws {
        let transport = AnthropicTestTransport(lines: [
            AnthropicWireFixtures.messageStart,
            AnthropicWireFixtures.errorEvent,
        ])

        await #expect(throws: (any Error).self) {
            _ = try await makeClient(transport: transport).chatStream(
                messages: [LLMMessage(role: .user, content: "hi")],
                tools: nil,
                toolChoice: nil,
                responseFormat: nil,
                generationParameters: nil
            ).collect()
        }
    }

    @Test("Non-2xx responses map to a typed provider HTTP failure")
    func httpFailureThrowsTypedError() async throws {
        let transport = AnthropicTestTransport(
            lines: [#"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#],
            statusCode: 401
        )

        await #expect(throws: (any Error).self) {
            _ = try await makeClient(transport: transport).chatStream(
                messages: [LLMMessage(role: .user, content: "hi")],
                tools: nil,
                toolChoice: nil,
                responseFormat: nil,
                generationParameters: nil
            ).collect()
        }
    }

    @Test("Anthropic sendMessage does not add a second retry loop")
    func sendMessageUsesSingleRetryLoop() async throws {
        let transport = AnthropicTestTransport(
            lines: [#"{"type":"error","error":{"type":"overloaded_error","message":"busy"}}"#],
            statusCode: 503
        )
        let client = makeClient(transport: transport, maxRetries: 1)

        do {
            _ = try await client.sendMessage("hi")
            Issue.record("Expected AnthropicClient.sendMessage() to throw")
        } catch {
            // The attempt count is the contract under test.
        }

        #expect(await transport.requestCount() == 2)
    }

    @Test("Anthropic rejects malformed tool history before invoking transport")
    func malformedToolHistoryDoesNotMakeRequest() async throws {
        let transport = AnthropicTestTransport(lines: [AnthropicWireFixtures.messageStop])
        let client = makeClient(transport: transport)
        let stream = await client.chatStream(
            messages: [LLMMessage(role: .tool, content: "result")],
            tools: nil,
            toolChoice: nil,
            responseFormat: nil,
            generationParameters: nil
        )

        do {
            _ = try await stream.collect()
            Issue.record("Expected malformed tool history to be rejected")
        } catch let error as LLMMessageValidationError {
            #expect(error.errorCode == 1005)
            #expect(error.remediation != nil)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(await transport.requestCount() == 0)
    }

    @Test("Request carries Anthropic headers, max_tokens default, and hoisted system param")
    func requestShapeMatchesMessagesAPI() async throws {
        let transport = AnthropicTestTransport(lines: [
            AnthropicWireFixtures.messageStart,
            AnthropicWireFixtures.messageDeltaEndTurn,
            AnthropicWireFixtures.messageStop,
        ])

        _ = try await makeClient(transport: transport).chatStream(
            messages: [
                LLMMessage(role: .system, content: "be terse"),
                LLMMessage(role: .user, content: "hi"),
            ],
            tools: nil,
            toolChoice: nil,
            responseFormat: nil,
            generationParameters: nil
        ).collect()

        let request = try #require(await transport.lastRequest())
        #expect(request.url?.path.hasSuffix("/v1/messages") == true)
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "secret")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")

        let body = try #require(request.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["system"] as? String == "be terse")
        #expect(json["max_tokens"] as? Int == AnthropicClient.defaultMaxTokens)
        #expect(json["stream"] as? Bool == true)
        // System messages are hoisted out of the messages array (the API rejects them inline).
        let messages = try #require(json["messages"] as? [[String: Any]])
        #expect(messages.count == 1)
        #expect(messages.first?["role"] as? String == "user")
    }
}

@Suite("Anthropic stop reason mapping")
struct AnthropicStopReasonMappingTests {
    @Test("stop_reason values map onto the shared FinishReason vocabulary (PKR-13)")
    func stopReasonsMapToFinishReasons() {
        #expect(mapAnthropicStopReason("end_turn") == .stop)
        #expect(mapAnthropicStopReason("stop_sequence") == .stop)
        #expect(mapAnthropicStopReason("max_tokens") == .length)
        #expect(mapAnthropicStopReason("tool_use") == .toolCalls)
        #expect(mapAnthropicStopReason("refusal") == .contentFilter)
        #expect(mapAnthropicStopReason("pause_turn") == .other("pause_turn"))
    }
}

@Suite("Anthropic message conversion")
struct AnthropicMessageConversionTests {
    private let logger = Logger.module(named: "anthropic-conversion-tests")

    @Test("Assistant tool calls and tool results preserve id pairing (PKINT-002)")
    func toolUseAndToolResultPreserveIdPairing() throws {
        let (system, messages) = try AnthropicMessageConversion.convert(
            messages: [
                LLMMessage(role: .system, content: "be helpful"),
                LLMMessage(role: .user, content: "weather in berlin?"),
                LLMMessage(
                    role: .assistant,
                    content: "",
                    toolCalls: [LLMToolCall(id: "toolu_01", name: "lookup_weather", arguments: #"{"city":"Berlin"}"#)]
                ),
                LLMMessage(role: .tool, content: "12°C", toolCallID: "toolu_01"),
            ],
            logger: logger
        )

        #expect(system == "be helpful")
        #expect(messages.count == 3)
        #expect(messages[0] == AnthropicMessage(role: "user", content: [.text("weather in berlin?")]))
        #expect(messages[1] == AnthropicMessage(
            role: "assistant",
            content: [.toolUse(id: "toolu_01", name: "lookup_weather", input: .object(["city": .string("Berlin")]))]
        ))
        // Tool results ride in a user-role message as tool_result blocks, pairing by tool_use_id.
        #expect(messages[2] == AnthropicMessage(
            role: "user",
            content: [.toolResult(toolUseID: "toolu_01", content: "12°C")]
        ))
    }

    @Test("Consecutive same-role messages merge into one alternating-turn message")
    func consecutiveSameRoleMessagesMerge() throws {
        let (_, messages) = try AnthropicMessageConversion.convert(
            messages: [
                LLMMessage(role: .user, content: "first"),
                LLMMessage(role: .user, content: "second"),
            ],
            logger: logger
        )

        #expect(messages.count == 1)
        #expect(messages[0] == AnthropicMessage(role: "user", content: [.text("first"), .text("second")]))
    }

    @Test("Multiple system/developer messages hoist into one top-level system param")
    func systemMessagesHoist() throws {
        let (system, messages) = try AnthropicMessageConversion.convert(
            messages: [
                LLMMessage(role: .system, content: "rule one"),
                LLMMessage(role: .developer, content: "rule two"),
                LLMMessage(role: .user, content: "hi"),
            ],
            logger: logger
        )

        #expect(system == "rule one\n\nrule two")
        #expect(messages.count == 1)
    }

    @Test("Invalid tool-call arguments JSON degrades to an empty input object, not a crash")
    func invalidToolArgumentsDegradeToEmptyObject() throws {
        let (_, messages) = try AnthropicMessageConversion.convert(
            messages: [
                LLMMessage(
                    role: .assistant,
                    content: "",
                    toolCalls: [LLMToolCall(id: "toolu_02", name: "broken", arguments: "{'not json'")]
                ),
            ],
            logger: logger
        )

        #expect(messages == [AnthropicMessage(
            role: "assistant",
            content: [.toolUse(id: "toolu_02", name: "broken", input: .object([:]))]
        )])
    }

    @Test("Tool-role message without toolCallID throws a typed validation error")
    func toolResultWithoutIDThrows() throws {
        do {
            _ = try AnthropicMessageConversion.convert(
                messages: [LLMMessage(role: .tool, content: "result")],
                logger: logger
            )
            Issue.record("Expected malformed tool history to be rejected")
        } catch let error as LLMMessageValidationError {
            #expect(error.errorDomain == PKErrorDomain.llm)
            #expect(error.errorCode == 1005)
            #expect(error.remediation != nil)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Ordered image input maps to Anthropic base64 blocks")
    func orderedImageInputMapsToBlocks() throws {
        let (_, messages) = try AnthropicMessageConversion.convert(
            messages: [LLMMessage(role: .user, content: MessageContent(parts: [
                .text("before"),
                .image(ImageContent(data: Data([0x01, 0x02]), mediaType: "image/png")),
                .text("after"),
            ]))],
            logger: logger
        )

        let encoded = try JSONEncoder().encode(messages)
        let array = try #require(JSONSerialization.jsonObject(with: encoded) as? [[String: Any]])
        let blocks = try #require(array.first?["content"] as? [[String: Any]])
        #expect(blocks.compactMap { $0["type"] as? String } == ["text", "image", "text"])
        #expect((blocks[1]["source"] as? [String: Any])?["media_type"] as? String == "image/png")
        #expect((blocks[1]["source"] as? [String: Any])?["data"] as? String == "AQI=")
    }
}
