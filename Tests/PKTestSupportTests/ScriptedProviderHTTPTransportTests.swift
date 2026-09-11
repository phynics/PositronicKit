import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
import PKTestSupport
import Testing

@Suite("Scripted provider HTTP transport")
struct ScriptedProviderHTTPTransportTests {
    @Test("Sequential data and line responses preserve request order")
    func sequentialResponsesAndRequests() async throws {
        let transport = ScriptedProviderHTTPTransport(responses: [
            .dataResponse(
                Data(#"{"models":[]}"#.utf8),
                statusCode: 200,
                headers: ["Content-Type": "application/json"]
            ),
            .linesResponse(
                ["first", "second"],
                statusCode: 206,
                headers: ["Content-Type": "text/event-stream"]
            ),
        ])
        let url = URL(string: "https://provider.test/fixture")!
        var firstRequest = URLRequest(url: url)
        firstRequest.httpMethod = "POST"
        let secondRequest = URLRequest(url: url.appendingPathComponent("stream"))

        let (data, dataResponse) = try await transport.data(for: firstRequest)
        #expect(data == Data(#"{"models":[]}"#.utf8))
        #expect((dataResponse as? HTTPURLResponse)?.statusCode == 200)

        let (stream, lineResponse) = try await transport.lines(for: secondRequest)
        var lines: [String] = []
        for try await line in stream { lines.append(line) }
        #expect(lines == ["first", "second"])
        #expect((lineResponse as? HTTPURLResponse)?.statusCode == 206)

        let requests = await transport.recordedRequests()
        #expect(requests.map(\.url) == [firstRequest.url, secondRequest.url])
    }

    @Test("Cancellation exposes an event-driven stream termination signal")
    func cancellationSignalsTermination() async {
        let transport = ScriptedProviderHTTPTransport(responses: [
            .linesUntilCancelled(
                ["partial"],
                HTTPURLResponse(
                    url: URL(string: "https://provider.test/stream")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
            ),
        ])
        let request = URLRequest(url: URL(string: "https://provider.test/stream")!)
        let (stream, _) = try! await transport.lines(for: request)
        let consumer = Task {
            do {
                for try await _ in stream {}
            } catch {
                // Cancellation is the expected terminal path.
            }
        }

        await transport.waitForRequest()
        consumer.cancel()
        await transport.waitForTermination()
        _ = await consumer.value
    }
}
