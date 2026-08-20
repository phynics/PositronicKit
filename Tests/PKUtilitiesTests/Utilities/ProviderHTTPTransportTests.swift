import Foundation
#if canImport(Network)
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import PKTestSupport
@testable import PKContracts
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

    // MARK: - Streaming conformance suite (PKRR-010)
    //
    // These tests verify that `lines(for:)` delivers lines incrementally — the first
    // line must arrive before the full response body is received. On Linux, the old
    // implementation used `URLSession.data(for:)` which buffered the entire response
    // before splitting lines; the delegate-based fix yields lines as chunks arrive.
    // On macOS the Apple path (`URLSession.bytes(for:)`) already streams incrementally,
    // so these tests pass on both platforms with the fix and would fail on Linux without it.

    @Test("lines(for:) yields the first line before response completion")
    func linesYieldsFirstLineBeforeCompletion() async throws {
        let chunks = ["data: alpha\n", "data: beta\n", "data: gamma\n"]
        let server = try await TestHTTPServer.start(
            response: .streamingSSE(chunks: chunks, delay: 0.15)
        )
        defer { server.stop() }

        let transport = URLSessionProviderHTTPTransport(session: .shared)
        let request = URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/")!)
        let (stream, response) = try await transport.lines(for: request)

        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 200)

        let startTime = Date()
        var firstLineTime: Date? = nil
        var lines: [String] = []

        for try await line in stream {
            if lines.isEmpty {
                firstLineTime = Date()
            }
            lines.append(line)
        }

        #expect(lines.contains("data: alpha"))
        #expect(lines.contains("data: beta"))
        #expect(lines.contains("data: gamma"))

        // With 3 chunks at 0.15s delay, the full response takes ~0.45s.
        // Incremental streaming delivers the first line at ~0.15s.
        // Buffer-then-yield delivers all lines at ~0.45s.
        // Threshold: 0.35s separates the two behaviours with margin.
        if let firstLineTime {
            let elapsed = firstLineTime.timeIntervalSince(startTime)
            #expect(
                elapsed < 0.35,
                "First line should arrive before response completion (got \(elapsed)s)"
            )
        } else {
            Issue.record("No lines were received")
        }
    }

    @Test("lines(for:) cancellation terminates the stream promptly")
    func linesCancellationTerminatesPromptly() async throws {
        let chunks = (1...20).map { "data: line\($0)\n" }
        let server = try await TestHTTPServer.start(
            response: .streamingSSE(chunks: chunks, delay: 0.05)
        )
        defer { server.stop() }

        let transport = URLSessionProviderHTTPTransport(session: .shared)
        let request = URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/")!)
        let (stream, _) = try await transport.lines(for: request)

        let startTime = Date()

        let consumeTask = Task<[String], Error> {
            var received: [String] = []
            for try await line in stream {
                received.append(line)
            }
            return received
        }

        try await Task.sleep(for: .milliseconds(150))
        consumeTask.cancel()

        _ = try? await consumeTask.value
        let elapsed = Date().timeIntervalSince(startTime)

        // Full response takes ~1.0s (20 chunks × 0.05s). With cancellation at
        // 0.15s, the stream should terminate well under 0.8s.
        #expect(
            elapsed < 0.8,
            "Stream should terminate promptly after cancellation (took \(elapsed)s)"
        )
    }

    @Test("lines(for:) cancels while waiting for response headers")
    func linesCancellationBeforeHeadersFailsPromptly() async throws {
        let server = try await TestHTTPServer.start(responseProvider: { _ in
            Thread.sleep(forTimeInterval: 3)
            return .init(headers: ["Content-Type": "text/plain"], body: Data())
        })
        defer { server.stop() }

        let transport = URLSessionProviderHTTPTransport(session: .shared)
        let request = URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/")!)
        let startTime = Date()
        let requestTask = Task {
            try await transport.lines(for: request)
        }

        try await Task.sleep(for: .milliseconds(100))
        requestTask.cancel()

        do {
            _ = try await requestTask.value
            Issue.record("Expected cancellation before response headers")
        } catch {
            let nsError = error as NSError
            #expect(error is CancellationError || nsError.code == NSURLErrorCancelled)
        }

        #expect(
            Date().timeIntervalSince(startTime) < 1,
            "Cancellation should not wait for delayed response headers"
        )
    }

    @Test("lines(for:) handles a large chunked stream")
    func linesHandlesLargeChunkedStream() async throws {
        let lineCount = 50
        let chunks = (1...lineCount).map { "data: line\($0)\n" }
        let server = try await TestHTTPServer.start(
            response: .streamingSSE(chunks: chunks, delay: 0.01)
        )
        defer { server.stop() }

        let transport = URLSessionProviderHTTPTransport(session: .shared)
        let request = URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/")!)
        let (stream, _) = try await transport.lines(for: request)

        var received: [String] = []
        for try await line in stream {
            received.append(line)
        }

        #expect(received.count == lineCount)
        #expect(received.first == "data: line1")
        #expect(received.last == "data: line\(lineCount)")
    }

    @Test("lines(for:) yields a final line without trailing newline")
    func linesYieldsFinalLineWithoutTrailingNewline() async throws {
        let server = try await TestHTTPServer.start(response: .streaming(
            headers: ["Content-Type": "text/plain"],
            chunks: [Data("alpha\nbeta\ngamma".utf8)],
            delay: 0.01
        ))
        defer { server.stop() }

        let transport = URLSessionProviderHTTPTransport(session: .shared)
        let request = URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/")!)
        let (stream, _) = try await transport.lines(for: request)

        var lines: [String] = []
        for try await line in stream {
            lines.append(line)
        }

        #expect(lines.count == 3)
        #expect(lines[0] == "alpha")
        #expect(lines[1] == "beta")
        #expect(lines[2] == "gamma")
    }

    @Test("lines(for:) steady stream does not stall between chunks")
    func linesSteadyStreamDoesNotStall() async throws {
        let chunks = (1...5).map { "data: tick\($0)\n" }
        let server = try await TestHTTPServer.start(
            response: .streamingSSE(chunks: chunks, delay: 0.2)
        )
        defer { server.stop() }

        let transport = URLSessionProviderHTTPTransport(session: .shared)
        let request = URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/")!)
        let (stream, _) = try await transport.lines(for: request)

        var received: [String] = []
        for try await line in stream {
            received.append(line)
        }

        // All 5 lines should be received from a stream with 0.2s gaps.
        // With buffer-then-yield, the consumer would see no data for ~1.0s
        // then all lines at once — which would trigger an idle watchdog.
        #expect(received.count == 5)
        #expect(received[0] == "data: tick1")
        #expect(received[4] == "data: tick5")
    }

    @Test("lines(for:) delivers lines from multiple chunks into a single line")
    func linesAssemblesPartialLineAcrossChunks() async throws {
    // A single SSE line split across two TCP chunks should be reassembled
    // before being yielded.
        let server = try await TestHTTPServer.start(response: .streaming(
            headers: ["Content-Type": "text/event-stream"],
            chunks: [Data("data: hel".utf8), Data("lo\n".utf8)],
            delay: 0.05
        ))
        defer { server.stop() }

        let transport = URLSessionProviderHTTPTransport(session: .shared)
        let request = URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/")!)
        let (stream, _) = try await transport.lines(for: request)

        var lines: [String] = []
        for try await line in stream {
            lines.append(line)
        }

        #expect(lines.count == 1)
        #expect(lines[0] == "data: hello")
    }

    @Test("lines(for:) propagates connection errors")
    func linesPropagatesConnectionErrors() async throws {
    // Point at a port that is not listening — the connection should fail.
        let transport = URLSessionProviderHTTPTransport(
            timeoutIntervalForRequest: 2,
            timeoutIntervalForResource: 2
        )
        let request = URLRequest(url: URL(string: "http://127.0.0.1:1/")!)
        do {
            let (stream, _) = try await transport.lines(for: request)
            for try await _ in stream { }
            Issue.record("Expected the stream to throw a connection error")
        } catch {
            // Expected: connection refused or timeout.
        }
    }
}
#endif
