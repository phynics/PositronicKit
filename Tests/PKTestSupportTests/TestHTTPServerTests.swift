import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import PKTestSupport
import Synchronization
import Testing

@Suite("TestHTTPServer", .serialized)
struct TestHTTPServerTests {
    @Test("parses a loopback HTTP request and returns the selected response")
    func requestParsingAndStaticResponse() async throws {
        let capturedRequest = Mutex<TestHTTPServer.Request?>(nil)
        let server = try await TestHTTPServer.start { request in
            capturedRequest.withLock { $0 = request }
            return .json(#"{"ok":true}"#)
        }
        defer { server.stop() }

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/v1/test?mode=full")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload = Data(#"{"input":"hello"}"#.utf8)
        request.setValue(String(payload.count), forHTTPHeaderField: "Content-Length")

        let (data, response) = try await URLSession.shared.upload(for: request, from: payload)
        let captured = try #require(capturedRequest.withLock { $0 })

        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(data == Data(#"{"ok":true}"#.utf8))
        #expect(captured.method == "POST")
        #expect(captured.path == "/v1/test?mode=full")
        #expect(captured.headers["Content-Type"] == "application/json")
        #expect(captured.body == payload)
    }

    @Test("delivers sequential and delayed chunked responses")
    func sequentialAndStreamingResponses() async throws {
        let sequentialServer = try await TestHTTPServer.startSequential(responses: [
            .json(#"{"attempt":1}"#),
            .streaming(chunks: [Data("{\"attempt\":".utf8), Data("2}".utf8)], delay: 0.01),
        ])
        defer { sequentialServer.stop() }

        let url = URL(string: "http://127.0.0.1:\(sequentialServer.port)/retry")!
        let (first, firstResponse) = try await URLSession.shared.data(from: url)
        let (second, secondResponse) = try await URLSession.shared.data(from: url)

        #expect((firstResponse as? HTTPURLResponse)?.statusCode == 200)
        #expect((secondResponse as? HTTPURLResponse)?.statusCode == 200)
        #expect(first == Data(#"{"attempt":1}"#.utf8))
        #expect(second == Data(#"{"attempt":2}"#.utf8))
    }
}
