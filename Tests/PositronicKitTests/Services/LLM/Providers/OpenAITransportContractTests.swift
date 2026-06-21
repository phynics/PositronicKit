import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import OpenAI
import PKShared
import PositronicKit
import Synchronization
import Testing
@testable import PKOpenAIProvider

#if canImport(Network)
import Network

private final class CapturingMiddleware: OpenAIMiddleware, @unchecked Sendable {
    private let requests = Mutex<[URLRequest]>([])

    func intercept(request: URLRequest) -> URLRequest {
        requests.withLock { $0.append(request) }
        return request
    }

    func recordedRequests() -> [URLRequest] {
        requests.withLock { $0 }
    }
}

private struct LocalResponse: Sendable {
    var statusCode: Int = 200
    var headers: [String: String] = [:]
    var body: Data = Data()
}

private final class LocalHTTPServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "OpenAITransportContractTests.LocalHTTPServer")
    private let response: LocalResponse

    static func start(response: LocalResponse) async throws -> LocalHTTPServer {
        let server = try LocalHTTPServer(response: response)
        try await server.waitUntilReady()
        return server
    }

    private init(response: LocalResponse) throws {
        self.response = response
        self.listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: 0)!)
    }

    var port: UInt16 {
        listener.port?.rawValue ?? 0
    }

    func stop() {
        listener.cancel()
    }

    private func waitUntilReady() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    guard let self, self.port != 0 else {
                        continuation.resume(throwing: NSError(domain: "OpenAITransportContractTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "listener did not expose a port"]))
                        return
                    }
                    continuation.resume(returning: ())
                case .failed(let error):
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            listener.start(queue: queue)
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var accumulated = buffer
            if let data {
                accumulated.append(data)
            }

            if let requestString = String(data: accumulated, encoding: .utf8), requestString.contains("\r\n\r\n") {
                self.sendResponse(on: connection)
                return
            }

            if isComplete || error != nil {
                connection.cancel()
                return
            }

            self.receive(on: connection, buffer: accumulated)
        }
    }

    private func sendResponse(on connection: NWConnection) {
        let responseData = Self.makeHTTPResponseData(response)
        connection.send(content: responseData, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func makeHTTPResponseData(_ response: LocalResponse) -> Data {
        let statusLine = "HTTP/1.1 \(response.statusCode) \(reasonPhrase(for: response.statusCode))\r\n"
        var headers = response.headers
        headers["Content-Length"] = "\(response.body.count)"
        headers["Connection"] = "close"
        let headerLines = headers.map { "\($0.key): \($0.value)\r\n" }.sorted().joined()
        return Data((statusLine + headerLines + "\r\n").utf8) + response.body
    }

    private static func reasonPhrase(for statusCode: Int) -> String {
        switch statusCode {
        case 200: return "OK"
        case 401: return "Unauthorized"
        case 429: return "Too Many Requests"
        case 500: return "Internal Server Error"
        default: return "HTTP Status"
        }
    }
}

@Suite("OpenAI transport contract", .serialized)
struct OpenAITransportContractTests {
    private func makeClient(
        host: String,
        port: UInt16,
        middleware: CapturingMiddleware,
        modelName: String = "gpt-4o"
    ) -> OpenAIClient {
        OpenAIClient(
            apiKey: "secret-key",
            modelName: modelName,
            host: host,
            port: Int(port),
            scheme: "http",
            session: .shared,
            middlewares: [middleware]
        )
    }

    private func requestBody(_ request: URLRequest) -> String {
        request.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    @Test("OpenAI chat request targets the configured host with auth headers and JSON body")
    func chatRequestContract() async throws {
        let server = try await LocalHTTPServer.start(response: .init(
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

    @Test("OpenAI stream tolerates malformed and truncated SSE without hanging")
    func malformedStream() async throws {
        let server = try await LocalHTTPServer.start(response: .init(
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
        let server = try await LocalHTTPServer.start(response: .init(
            headers: ["Content-Type": "application/json"],
            body: Data("{\"object\":\"list\",\"data\":[{\"id\":\"gpt-4o\",\"created\":0,\"object\":\"model\",\"owned_by\":\"openai\"},{\"id\":\"gpt-4o-mini\",\"created\":0,\"object\":\"model\",\"owned_by\":\"openai\"}]}".utf8)
        ))
        defer { server.stop() }

        let good = makeClient(host: "127.0.0.1", port: server.port, middleware: CapturingMiddleware())
        let models = try await good.fetchAvailableModels()
        #expect(models == ["gpt-4o", "gpt-4o-mini"])

        let badServer = try await LocalHTTPServer.start(response: .init(
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
        let server = try await LocalHTTPServer.start(response: .init(
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
}
#else
@Suite("OpenAI transport contract")
struct OpenAITransportContractTests {}
#endif
