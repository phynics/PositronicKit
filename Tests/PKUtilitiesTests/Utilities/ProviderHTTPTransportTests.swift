import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import PKTestSupport
@testable import PKShared
@testable import PKUtilities
import Testing

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
        let server = try await TestHTTPServer.start(response: .json(#"{"ok":true}"#))
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
        let server = try await TestHTTPServer.start(response: .init(
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
        let server = try await TestHTTPServer.start(response: .init(
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
        let server = try await TestHTTPServer.start(response: .init(
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
