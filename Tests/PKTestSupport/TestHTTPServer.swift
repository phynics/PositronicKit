import Foundation
#if canImport(Network)
import Network
import Synchronization

/// A lightweight local HTTP server for testing provider transport layers.
///
/// Listens on an ephemeral port and returns a canned response for every request. Use this
/// instead of hand-rolling `NWListener` boilerplate in every provider test target.
///
/// ```swift
/// let server = try await TestHTTPServer.start(response: .init(
///     headers: ["Content-Type": "text/event-stream"],
///     body: Data("data: ...".utf8)
/// ))
/// defer { server.stop() }
/// // Point your client at "http://127.0.0.1:\(server.port)"
/// ```
public final class TestHTTPServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "TestHTTPServer")
    private let responseProvider: @Sendable (Request) -> Response

    /// The port the server is listening on.
    public var port: UInt16 {
        listener.port?.rawValue ?? 0
    }

    /// A captured HTTP request received by the server.
    public struct Request: Sendable {
        public let method: String
        public let path: String
        public let headers: [String: String]
        public let body: Data
    }

    /// A canned HTTP response.
    public struct Response: Sendable {
        public var statusCode: Int = 200
        public var headers: [String: String] = [:]
        public var body: Data = Data()
        public var chunkedBody: [Data]? = nil
        public var chunkDelay: TimeInterval = 0.05

        public init(
            statusCode: Int = 200,
            headers: [String: String] = [:],
            body: Data = Data(),
            chunkedBody: [Data]? = nil,
            chunkDelay: TimeInterval = 0.05
        ) {
            self.statusCode = statusCode
            self.headers = headers
            self.body = body
            self.chunkedBody = chunkedBody
            self.chunkDelay = chunkDelay
        }

        /// SSE response with the given event-stream body.
        public static func sse(_ body: String) -> Response {
            Response(
                headers: ["Content-Type": "text/event-stream"],
                body: Data(body.utf8)
            )
        }

        /// JSON response with the given body.
        public static func json(_ body: String, statusCode: Int = 200) -> Response {
            Response(
                statusCode: statusCode,
                headers: ["Content-Type": "application/json"],
                body: Data(body.utf8)
            )
        }

        /// Streaming response that sends body chunks one at a time with a delay
        /// between each chunk. The total `Content-Length` header is set to the
        /// combined size of all chunks so the client knows the full body size.
        /// Use this to verify incremental delivery (first-chunk-before-completion).
        public static func streaming(
            statusCode: Int = 200,
            headers: [String: String] = [:],
            chunks: [Data],
            delay: TimeInterval = 0.05
        ) -> Response {
            Response(
                statusCode: statusCode,
                headers: headers,
                body: Data(),
                chunkedBody: chunks,
                chunkDelay: delay
            )
        }

        /// SSE streaming response that sends each chunk as a separate TCP write
        /// with a delay between them.
        public static func streamingSSE(
            chunks: [String],
            delay: TimeInterval = 0.05
        ) -> Response {
            streaming(
                headers: ["Content-Type": "text/event-stream"],
                chunks: chunks.map { Data($0.utf8) },
                delay: delay
            )
        }
    }

    /// Starts a server that always returns the same response.
    public static func start(response: Response) async throws -> TestHTTPServer {
        try await start { _ in response }
    }

    /// Starts a server that selects a response based on the request (e.g. different
    /// responses for the first vs. subsequent requests).
    public static func start(
        responseProvider: @escaping @Sendable (Request) -> Response
    ) async throws -> TestHTTPServer {
        let server = try TestHTTPServer(responseProvider: responseProvider)
        try await server.waitUntilReady()
        return server
    }

    /// Starts a server that returns a different response for each sequential request,
    /// cycling through the provided list. Useful for testing recovery paths that issue a
    /// streaming request followed by a non-streaming request.
    public static func startSequential(
        responses: [Response]
    ) async throws -> TestHTTPServer {
        let counter = Mutex(0)
        return try await start { _ in
            counter.withLock { c -> Response in
                let index = min(c, responses.count - 1)
                c += 1
                return responses[index]
            }
        }
    }

    private init(responseProvider: @escaping @Sendable (Request) -> Response) throws {
        self.responseProvider = responseProvider
        self.listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: 0)!)
    }

    /// Stops the server.
    public func stop() {
        listener.cancel()
    }

    private func waitUntilReady() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    guard let self, self.port != 0 else {
                        continuation.resume(throwing: NSError(
                            domain: "TestHTTPServer", code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "listener did not expose a port"]
                        ))
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

            if let requestString = String(data: accumulated, encoding: .utf8),
               requestString.contains("\r\n\r\n")
            {
                let request = Self.parseRequest(accumulated)
                let response = self.responseProvider(request)
                self.sendResponse(on: connection, response: response)
                return
            }

            if isComplete || error != nil {
                connection.cancel()
                return
            }

            self.receive(on: connection, buffer: accumulated)
        }
    }

    private static func parseRequest(_ data: Data) -> Request {
        let raw = String(data: data, encoding: .utf8) ?? ""
        let parts = raw.components(separatedBy: "\r\n\r\n")
        let headerBlock = parts.first ?? ""
        let body = parts.count > 1 ? Data(parts.dropFirst().joined(separator: "\r\n\r\n").utf8) : Data()

        var method = ""
        var path = ""
        var headers: [String: String] = [:]

        for line in headerBlock.components(separatedBy: "\r\n") {
            if method.isEmpty {
                let comps = line.components(separatedBy: " ")
                if comps.count >= 2 {
                    method = comps[0]
                    path = comps[1]
                }
            } else {
                if let colonIndex = line.firstIndex(of: ":") {
                    let key = String(line[..<colonIndex]).trimmingCharacters(in: .whitespaces)
                    let value = String(line[line.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
                    headers[key] = value
                }
            }
        }

        return Request(method: method, path: path, headers: headers, body: body)
    }

    private func sendResponse(on connection: NWConnection, response: Response) {
        if let chunks = response.chunkedBody {
            sendChunkedResponse(on: connection, response: response, chunks: chunks, delay: response.chunkDelay)
        } else {
            let responseData = Self.makeHTTPResponseData(response)
            connection.send(content: responseData, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    private func sendChunkedResponse(
        on connection: NWConnection,
        response: Response,
        chunks: [Data],
        delay: TimeInterval
    ) {
        let totalSize = chunks.reduce(0) { $0 + $1.count }
        let headerData = Self.makeHTTPResponseHeader(response: response, contentLength: totalSize)
        connection.send(content: headerData, completion: .contentProcessed { _ in })

        for (index, chunk) in chunks.enumerated() {
            let isLast = index == chunks.count - 1
            queue.asyncAfter(deadline: .now() + delay * Double(index + 1)) {
                connection.send(content: chunk, completion: .contentProcessed { _ in
                    if isLast {
                        connection.cancel()
                    }
                })
            }
        }
    }

    private static func makeHTTPResponseData(_ response: Response) -> Data {
        makeHTTPResponseHeader(response: response, contentLength: response.body.count) + response.body
    }

    private static func makeHTTPResponseHeader(response: Response, contentLength: Int) -> Data {
        let statusLine = "HTTP/1.1 \(response.statusCode) \(reasonPhrase(for: response.statusCode))\r\n"
        var headers = response.headers
        headers["Content-Length"] = "\(contentLength)"
        headers["Connection"] = "close"
        let headerLines = headers.map { "\($0.key): \($0.value)\r\n" }.sorted().joined()
        return Data((statusLine + headerLines + "\r\n").utf8)
    }

    private static func reasonPhrase(for statusCode: Int) -> String {
        switch statusCode {
        case 200: return "OK"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 429: return "Too Many Requests"
        case 500: return "Internal Server Error"
        default: return "HTTP Status"
        }
    }
}
#endif
