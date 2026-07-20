import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import PKShared
@testable import PKUtilities
import Testing

#if canImport(Network)
import Network

/// Coverage for `URLSessionProviderHTTPTransport` — the concrete `URLSession`-backed
/// HTTP transport used by all provider clients (Anthropic, Ollama, OpenRouter).
///
/// The `init(session:)`, `data(for:)`, and `lines(for:)` methods were previously
/// untested — only the `init(timeoutIntervalForRequest:)` constructor was exercised
/// indirectly through provider client tests. These tests drive the transport directly
/// against a local HTTP server.
@Suite("URLSessionProviderHTTPTransport", .serialized)
struct ProviderHTTPTransportTests {

    @Test("init(session:) accepts a custom URLSession")
    func initWithCustomSession() async throws {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 5
        let session = URLSession(configuration: config)
        let transport = URLSessionProviderHTTPTransport(session: session)
        // Verify it doesn't crash on construction.
        _ = transport
    }

    @Test("data(for:) returns the response body and URLResponse")
    func dataReturnsBodyAndResponse() async throws {
        let server = try await LocalServer.start(response: .init(
            headers: ["Content-Type": "application/json"],
            body: Data(#"{"ok":true}"#.utf8)
        ))
        defer { server.stop() }

        let transport = URLSessionProviderHTTPTransport(session: .shared)
        let request = URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/")!)
        let (data, response) = try await transport.data(for: request)

        #expect(String(data: data, encoding: .utf8) == #"{"ok":true}"#)
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 200)
    }

    @Test("data(for:) propagates HTTP error status codes")
    func dataPropagatesErrorStatus() async throws {
        let server = try await LocalServer.start(response: .init(
            statusCode: 500,
            headers: ["Content-Type": "text/plain"],
            body: Data("internal error".utf8)
        ))
        defer { server.stop() }

        let transport = URLSessionProviderHTTPTransport(session: .shared)
        let request = URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/")!)
        let (data, response) = try await transport.data(for: request)

        // data(for:) returns the body even for error status codes — the caller checks the status.
        #expect(String(data: data, encoding: .utf8) == "internal error")
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 500)
    }

    @Test("lines(for:) streams response body line by line")
    func linesStreamsLineByLine() async throws {
        let body = "line1\nline2\nline3\n"
        let server = try await LocalServer.start(response: .init(
            headers: ["Content-Type": "text/plain"],
            body: Data(body.utf8)
        ))
        defer { server.stop() }

        let transport = URLSessionProviderHTTPTransport(session: .shared)
        let request = URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/")!)
        let (stream, response) = try await transport.lines(for: request)

        var lines: [String] = []
        for try await line in stream {
            lines.append(line)
        }

        #expect(lines.count >= 3)
        #expect(lines.contains("line1"))
        #expect(lines.contains("line2"))
        #expect(lines.contains("line3"))
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 200)
    }

    @Test("lines(for:) handles empty response body")
    func linesHandlesEmptyBody() async throws {
        let server = try await LocalServer.start(response: .init(
            headers: ["Content-Type": "text/plain"],
            body: Data()
        ))
        defer { server.stop() }

        let transport = URLSessionProviderHTTPTransport(session: .shared)
        let request = URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/")!)
        let (stream, _) = try await transport.lines(for: request)

        var count = 0
        for try await _ in stream {
            count += 1
        }
        #expect(count == 0)
    }

    @Test("init(timeoutIntervalForRequest:) configures the session timeout")
    func initWithTimeout() async throws {
        let transport = URLSessionProviderHTTPTransport(
            timeoutIntervalForRequest: 30,
            timeoutIntervalForResource: 60,
            waitsForConnectivity: true
        )
        // Verify it doesn't crash; the session is configured internally.
        _ = transport
    }

    @Test("init(timeoutIntervalForRequest:) works without optional parameters")
    func initWithTimeoutNoOptionalParams() async throws {
        let transport = URLSessionProviderHTTPTransport(timeoutIntervalForRequest: 10)
        _ = transport
    }
}

// MARK: - Local HTTP server

private final class LocalServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "ProviderHTTPTransportTests.LocalServer")
    private let response: HTTPResponse

    static func start(response: HTTPResponse) async throws -> LocalServer {
        let server = try LocalServer(response: response)
        try await server.waitUntilReady()
        return server
    }

    private init(response: HTTPResponse) throws {
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
                        continuation.resume(throwing: NSError(domain: "LocalServer", code: 1, userInfo: [NSLocalizedDescriptionKey: "no port"]))
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

    private static func makeHTTPResponseData(_ response: HTTPResponse) -> Data {
        let statusLine = "HTTP/1.1 \(response.statusCode) OK\r\n"
        var headers = response.headers
        headers["Content-Length"] = "\(response.body.count)"
        headers["Connection"] = "close"
        let headerLines = headers.map { "\($0.key): \($0.value)\r\n" }.sorted().joined()
        return Data((statusLine + headerLines + "\r\n").utf8) + response.body
    }
}

private struct HTTPResponse: Sendable {
    var statusCode: Int = 200
    var headers: [String: String] = [:]
    var body: Data = Data()
}

#else
@Suite("URLSessionProviderHTTPTransport")
struct ProviderHTTPTransportTests {}
#endif
