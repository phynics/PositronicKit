import PKShared
import PKTestSupport
import PositronicKit
import Testing

@Suite("MockLLMClient contracts")
struct MockLLMClientContractTests {
    @Test("concurrent streams consume each queued response exactly once")
    func concurrentStreamsConsumeEachQueuedResponseExactlyOnce() async throws {
        let client = MockLLMClient()
        let expected = Set((0 ..< 100).map { "response-\($0)" })
        client.nextResponses = Array(expected)

        let actual = try await withThrowingTaskGroup(of: String.self, returning: [String].self) { group in
            for _ in 0 ..< expected.count {
                group.addTask { try await streamText(from: client) }
            }

            var results: [String] = []
            for try await result in group {
                results.append(result)
            }
            return results
        }

        #expect(actual.count == expected.count)
        #expect(Set(actual) == expected)
        #expect(client.streamCallCount == expected.count)
        #expect(client.chatCaptureHistory.count == expected.count)
    }

    @Test("script queues follow raw chunks, chunks, responses, fallback precedence")
    func scriptQueuesFollowPrecedence() async throws {
        let client = MockLLMClient()
        client.nextRawStreamChunks = [[ChatStreamResultFactory.textChunk("raw")]]
        client.nextChunks = [["chunk-a", "chunk-b"]]
        client.nextResponses = ["queued"]
        client.nextResponse = "fallback"

        let outputs = try await (0 ..< 4).asyncMap { _ in
            try await streamText(from: client)
        }

        #expect(outputs == ["raw", "chunk-achunk-b", "queued", "fallback"])
    }

    @Test("chat capture preserves every supplied field, including throwing calls")
    func chatCapturePreservesEverySuppliedFieldIncludingThrowingCalls() async throws {
        let client = MockLLMClient()
        let messages = [LLMMessage(role: .user, content: "hello")]
        let tools = [LLMToolDefinition(name: "echo", description: "Echo input")]
        let parameters = GenerationParameters(temperature: 0.25, maxTokens: 42)

        _ = await client.chatStream(
            messages: messages,
            tools: tools,
            toolChoice: .function("echo"),
            responseFormat: .jsonObject,
            generationParameters: parameters
        )

        let capture = client.lastChatCapture
        #expect(capture?.messages == messages)
        #expect(capture?.tools?.map(\.name) == ["echo"])
        #expect(capture?.toolChoice == .function("echo"))
        #expect(capture?.responseFormat == .jsonObject)
        #expect(capture?.generationParameters == parameters)
        #expect(capture?.modelTier == .primary)

        client.shouldThrowError = true
        let failingStream = await client.chatStream(
            messages: [LLMMessage(role: .user, content: "failing")],
            tools: nil,
            toolChoice: nil,
            responseFormat: nil,
            generationParameters: nil
        )
        do {
            _ = try await failingStream.collect()
            Issue.record("Expected the configured stream error")
        } catch {}

        #expect(client.chatCaptureHistory.count == 2)
        #expect(client.lastChatCapture?.messages.first?.content == "failing")
    }

    @Test("send capture preserves content, options, and throwing calls")
    func sendCapturePreservesContentOptionsAndThrowingCalls() async throws {
        let client = MockLLMClient()
        let parameters = GenerationParameters(seed: 7)
        client.nextResponse = "ok"

        let response = try await client.sendMessage(
            "hello",
            responseFormat: .jsonObject,
            generationParameters: parameters
        )

        #expect(response == "ok")
        #expect(client.lastSendMessageCapture?.content == "hello")
        #expect(client.lastSendMessageCapture?.responseFormat == .jsonObject)
        #expect(client.lastSendMessageCapture?.generationParameters == parameters)
        #expect(client.lastSendMessageCapture?.useUtilityModel == false)

        client.shouldThrowError = true
        do {
            _ = try await client.sendMessage(
                "failing",
                responseFormat: .text,
                generationParameters: nil
            )
            Issue.record("Expected the configured send error")
        } catch {}

        #expect(client.sendMessageCaptureHistory.count == 2)
        #expect(client.lastSendMessageCapture?.content == "failing")
    }

    private func streamText(from client: MockLLMClient) async throws -> String {
        let stream = await client.chatStream(
            messages: [],
            tools: nil,
            toolChoice: nil,
            responseFormat: nil,
            generationParameters: nil
        )
        return try await stream.collect().compactMap { $0.choices.first?.delta.content }.joined()
    }
}

private extension Sequence {
    func asyncMap<Result>(_ transform: (Element) async throws -> Result) async rethrows -> [Result] {
        var results: [Result] = []
        for element in self {
            results.append(try await transform(element))
        }
        return results
    }
}
