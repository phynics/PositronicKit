import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
@testable import PKOpenRouterProvider
import PKShared
import PKUtilities
import Testing

private actor ToolChoiceRecordingTransport: ProviderHTTPTransport {
    private var requestBodies: [Data] = []

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        record(request)
        return (Data(#"{"data":[]}"#.utf8), response(for: request))
    }

    func lines(for request: URLRequest) async throws -> (AsyncThrowingStream<String, Error>, URLResponse) {
        record(request)
        let stream = AsyncThrowingStream<String, Error> { continuation in
            continuation.yield("data: [DONE]")
            continuation.finish()
        }
        return (stream, response(for: request))
    }

    func lastRequestBody() -> Data? {
        requestBodies.last
    }

    private func record(_ request: URLRequest) {
        if let httpBody = request.httpBody {
            requestBodies.append(httpBody)
        }
    }

    private func response(for request: URLRequest) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url ?? URL(string: "https://example.invalid")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
    }
}

@Suite("OpenRouter tool choice")
struct OpenRouterToolChoiceTests {
    @Test("Explicit LLMToolChoice.none is encoded when tools are present")
    func explicitNoneIsEncodedWithTools() async throws {
        let transport = ToolChoiceRecordingTransport()
        let client = OpenRouterClient(
            apiKey: "test",
            baseURL: URL(string: "https://example.invalid/api")!,
            maxRetries: 0,
            transport: transport
        )

        let stream = await client.chatStream(
            messages: [LLMMessage(role: .user, content: "Do not use tools")],
            tools: [LLMToolDefinition(name: "side_effecting_tool")],
            toolChoice: LLMToolChoice.none,
            responseFormat: nil,
            generationParameters: nil
        )
        for try await _ in stream {}

        let body = try #require(await transport.lastRequestBody())
        let payload = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(payload["tool_choice"] as? String == "none")
    }

    @Test("An omitted tool choice retains auto selection when tools are present")
    func omittedChoiceRemainsAutoWithTools() async throws {
        let transport = ToolChoiceRecordingTransport()
        let client = OpenRouterClient(
            apiKey: "test",
            baseURL: URL(string: "https://example.invalid/api")!,
            maxRetries: 0,
            transport: transport
        )

        let stream = await client.chatStream(
            messages: [LLMMessage(role: .user, content: "You may use tools")],
            tools: [LLMToolDefinition(name: "side_effecting_tool")],
            toolChoice: nil,
            responseFormat: nil,
            generationParameters: nil
        )
        for try await _ in stream {}

        let body = try #require(await transport.lastRequestBody())
        let payload = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(payload["tool_choice"] as? String == "auto")
    }
}
