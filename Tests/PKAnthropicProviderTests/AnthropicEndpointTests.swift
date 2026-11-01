import Foundation
@testable import PKAnthropicProvider
import PKContracts
import PKTestSupport
import PKUtilities
import Testing

@Suite("Anthropic endpoint construction")
struct AnthropicEndpointTests {
    @Test("Requests retain mismatched standard ports and omit matching defaults")
    func requestPortsFollowScheme() async throws {
        let cases: [(String, Int, String)] = [
            ("http", 443, "http://api.example.test:443/v1/messages"),
            ("https", 80, "https://api.example.test:80/v1/messages"),
            ("http", 80, "http://api.example.test/v1/messages"),
            ("https", 443, "https://api.example.test/v1/messages"),
            ("http", 443, "http://[::1]:443/v1/messages"),
        ]

        for (index, (scheme, port, expectedURL)) in cases.enumerated() {
            let transport = ScriptedProviderHTTPTransport(lines: [
                #"data: {"type":"message_start","message":{"id":"msg_01","model":"claude-sonnet-4-5","usage":{"input_tokens":1}}}"#,
                #"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":1}}"#,
                #"data: {"type":"message_stop"}"#,
            ])
            let client = AnthropicClient(
                apiKey: "test",
                host: index == 4 ? "::1" : "api.example.test",
                port: port,
                scheme: scheme,
                maxRetries: 0,
                transport: transport
            )

            for try await _ in await client.chatStream(
                messages: [LLMMessage(role: .user, content: "hello")],
                tools: nil,
                toolChoice: nil,
                responseFormat: nil,
                generationParameters: nil
            ) {}

            let actualURLs = await transport.requestURLs().map(\.absoluteString)
            #expect(actualURLs == [expectedURL], "\(scheme) port \(port): \(actualURLs)")
        }
    }
}
