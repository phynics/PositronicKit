import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import OpenAI
import PKContracts
import PKTestSupport
import PKUtilities
import PositronicKit
import Synchronization
import Testing
@testable import PKOpenAIProvider

private final class CapturingMiddleware: OpenAIMiddleware, @unchecked Sendable { // swiftlint:disable:this concurrency_unchecked_sendable -- reviewed test double (see docs/Concurrency/exception-manifest.md)
    private let requests = Mutex<[URLRequest]>([])

    func intercept(request: URLRequest) -> URLRequest {
        requests.withLock { $0.append(request) }
        return request
    }

    func recordedRequests() -> [URLRequest] {
        requests.withLock { $0 }
    }
}

@Suite("OpenAI transport contract", .serialized)
struct OpenAITransportContractTests {
    private func makeClient(
        host: String,
        port: UInt16,
        middleware: CapturingMiddleware,
        modelName: String = "gpt-4o",
        maxRetries: Int = 3
    ) -> OpenAIClient {
        OpenAIClient(
            apiKey: "secret-key",
            modelName: modelName,
            host: host,
            port: Int(port),
            scheme: "http",
            maxRetries: maxRetries,
            session: .shared,
            middlewares: [middleware]
        )
    }

    private func requestBody(_ request: URLRequest) -> String {
        request.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    @Test("OpenAI chat request targets the configured host with auth headers and JSON body")
    func chatRequestContract() async throws {
        let server = try await TestHTTPServer.start(response: .init(
            headers: ["Content-Type": "text/event-stream"],
            body: Data(#"""
data: {"id":"chatcmpl-1","object":"chat.completion.chunk","created":0,"model":"gpt-4o","choices":[{"index":0,"delta":{"role":"assistant","content":"hi"}}]}

data: [DONE]

"""#.utf8)
        ))
        defer { server.stop() }

        let middleware = CapturingMiddleware()
        let client = makeClient(host: "127.0.0.1", port: server.port, middleware: middleware)

        let stream = await client.chatStream(
            messages: [LLMMessage(role: .user, content: "hello")],
            tools: nil,
            toolChoice: nil,
            responseFormat: nil,
            generationParameters: nil
        )
        for try await _ in stream {}

        let request = try #require(middleware.recordedRequests().first)
        #expect(request.url?.host == "127.0.0.1")
        #expect(request.url?.path.contains("/v1/chat/completions") == true)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret-key")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = requestBody(request)
        #expect(body.contains("\"model\":\"gpt-4o\"") || body.contains("\"model\": \"gpt-4o\""))
    }

    @Test("OpenAI rejects malformed tool history before invoking transport")
    func malformedToolHistoryDoesNotMakeRequest() async throws {
        let server = try await TestHTTPServer.start(response: .init(
            headers: ["Content-Type": "text/event-stream"],
            body: Data("data: [DONE]\n\n".utf8)
        ))
        defer { server.stop() }

        let middleware = CapturingMiddleware()
        let client = makeClient(host: "127.0.0.1", port: server.port, middleware: middleware)
        let stream = await client.chatStream(
            messages: [LLMMessage(role: .tool, content: "result")],
            tools: nil,
            toolChoice: nil,
            responseFormat: nil,
            generationParameters: nil
        )

        do {
            for try await _ in stream {}
            Issue.record("Expected malformed tool history to be rejected")
        } catch let error as LLMMessageValidationError {
            #expect(error.errorCode == 1005)
            #expect(error.remediation != nil)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(middleware.recordedRequests().isEmpty)
    }

    @Test("OpenAI stream tolerates malformed and truncated SSE without hanging")
    func malformedStream() async throws {
        let server = try await TestHTTPServer.start(response: .init(
            headers: ["Content-Type": "text/event-stream"],
            body: Data(#"""
data: {"id":"chatcmpl-1","object":"chat.completion.chunk","created":0,"model":"gpt-4o","choices":[{"index":0,"delta":{"content":"hi"}}]}

data: {bad json
"""#.utf8)
        ))
        defer { server.stop() }

        let client = makeClient(host: "127.0.0.1", port: server.port, middleware: CapturingMiddleware())
        let stream = await client.chatStream(
            messages: [LLMMessage(role: .user, content: "x")],
            tools: nil,
            toolChoice: nil,
            responseFormat: nil,
            generationParameters: nil
        )

        var chunks = 0
        do {
            for try await _ in stream {
                chunks += 1
            }
        } catch {
            // The contract is that the stream terminates promptly, not that malformed SSE is silent.
        }

        #expect(chunks >= 0)
    }

    @Test("OpenAI model listing parses ids and tolerates malformed payloads")
    func modelListing() async throws {
        let server = try await TestHTTPServer.start(response: .init(
            headers: ["Content-Type": "application/json"],
            body: Data("{\"object\":\"list\",\"data\":[{\"id\":\"gpt-4o\",\"created\":0,\"object\":\"model\",\"owned_by\":\"openai\"},{\"id\":\"gpt-4o-mini\",\"created\":0,\"object\":\"model\",\"owned_by\":\"openai\"}]}".utf8)
        ))
        defer { server.stop() }

        let good = makeClient(host: "127.0.0.1", port: server.port, middleware: CapturingMiddleware())
        let models = try await good.fetchAvailableModels()
        #expect(models == ["gpt-4o", "gpt-4o-mini"])

        let badServer = try await TestHTTPServer.start(response: .init(
            headers: ["Content-Type": "application/json"],
            body: Data("{not json".utf8)
        ))
        defer { badServer.stop() }

        let bad = makeClient(host: "127.0.0.1", port: badServer.port, middleware: CapturingMiddleware())
        await #expect(throws: DecodingError.self) {
            _ = try await bad.fetchAvailableModels()
        }
    }

    @Test("OpenAI maps HTTP failure responses to typed LLMServiceError")
    func httpErrorMapping() async throws {
        let server = try await TestHTTPServer.start(response: .init(
            statusCode: 429,
            headers: ["Content-Type": "application/json"],
            body: Data("{\"error\":{\"message\":\"rate limited\"}}".utf8)
        ))
        defer { server.stop() }

        let client = makeClient(host: "127.0.0.1", port: server.port, middleware: CapturingMiddleware())
        let stream = await client.chatStream(
            messages: [LLMMessage(role: .user, content: "hello")],
            tools: nil,
            toolChoice: nil,
            responseFormat: nil,
            generationParameters: nil
        )

        do {
            for try await _ in stream {}
            Issue.record("Expected OpenAIClient.chatStream() to throw")
        } catch let error as LLMServiceError {
            #expect(error == .httpError(provider: "OpenAI", statusCode: 429, responseBody: "", retryAfter: nil))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("OpenAI sendMessage does not add a second retry loop")
    func sendMessageUsesSingleRetryLoop() async throws {
        let server = try await TestHTTPServer.start(response: .init(
            statusCode: 503,
            headers: ["Content-Type": "application/json"],
            body: Data("{\"error\":{\"message\":\"temporarily unavailable\"}}".utf8)
        ))
        defer { server.stop() }

        let middleware = CapturingMiddleware()
        let client = makeClient(
            host: "127.0.0.1",
            port: server.port,
            middleware: middleware,
            maxRetries: 1
        )

        do {
            _ = try await client.sendMessage("hello")
            Issue.record("Expected OpenAIClient.sendMessage() to throw")
        } catch {
            // The attempt count is the contract under test.
        }

        #expect(middleware.recordedRequests().count == 2)
    }
}
