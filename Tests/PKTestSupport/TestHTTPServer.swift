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

            let delimiter = Data([0x0D, 0x0A, 0x0D, 0x0A])
            if let delimiterRange = accumulated.range(of: delimiter),
               let headerString = String(data: accumulated[..<delimiterRange.lowerBound], encoding: .utf8)
            {
                let contentLength = headerString
                    .components(separatedBy: "\r\n")
                    .first { $0.lowercased().hasPrefix("content-length:") }
                    .flatMap { Int($0.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces) ?? "") } ?? 0
                let bodyLength = accumulated.distance(from: delimiterRange.upperBound, to: accumulated.endIndex)
                guard bodyLength >= contentLength else {
                    self.receive(on: connection, buffer: accumulated)
                    return
                }

                let requestEnd = delimiterRange.upperBound + contentLength
                let request = Self.parseRequest(Data(accumulated[..<requestEnd]))
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
#else
import Glibc
import Synchronization

/// A lightweight local HTTP server for testing provider transport layers.
///
/// This POSIX implementation provides the same API as the Network-backed server used
/// on Apple platforms, while keeping Linux provider tests on a real loopback transport.
public final class TestHTTPServer: @unchecked Sendable {
    private struct State: Sendable {
        var isStopped = false
        var activeConnections: Set<Int32> = []
    }

    private let listeningSocket: Int32
    private let boundPort: UInt16
    private let acceptQueue = DispatchQueue(label: "TestHTTPServer.accept")
    private let connectionQueue = DispatchQueue(label: "TestHTTPServer.connection", attributes: .concurrent)
    private let responseProvider: @Sendable (Request) -> Response
    private let state = Mutex(State())

    /// The port the server is listening on.
    public var port: UInt16 { boundPort }

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
            Response(headers: ["Content-Type": "text/event-stream"], body: Data(body.utf8))
        }

        /// JSON response with the given body.
        public static func json(_ body: String, statusCode: Int = 200) -> Response {
            Response(statusCode: statusCode, headers: ["Content-Type": "application/json"], body: Data(body.utf8))
        }

        /// Streaming response that sends body chunks one at a time with a delay
        /// between each chunk. The total `Content-Length` header is set to the
        /// combined size of all chunks so the client knows the full body size.
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
        public static func streamingSSE(chunks: [String], delay: TimeInterval = 0.05) -> Response {
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
        server.startAccepting()
        return server
    }

    /// Starts a server that returns a different response for each sequential request,
    /// cycling through the provided list.
    public static func startSequential(responses: [Response]) async throws -> TestHTTPServer {
        precondition(!responses.isEmpty, "TestHTTPServer.startSequential requires at least one response")
        let counter = Mutex(0)
        return try await start { _ in
            counter.withLock { index in
                defer { index += 1 }
                return responses[min(index, responses.count - 1)]
            }
        }
    }

    private init(responseProvider: @escaping @Sendable (Request) -> Response) throws {
        self.responseProvider = responseProvider

        let socket = Glibc.socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        guard socket >= 0 else { throw Self.posixError() }
        self.listeningSocket = socket

        var reuseAddress: Int32 = 1
        guard Glibc.setsockopt(
            socket,
            SOL_SOCKET,
            SO_REUSEADDR,
            &reuseAddress,
            socklen_t(MemoryLayout<Int32>.size)
        ) == 0 else {
            Glibc.close(socket)
            throw Self.posixError()
        }

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: Glibc.inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Glibc.bind(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            Glibc.close(socket)
            throw Self.posixError()
        }
        guard Glibc.listen(socket, SOMAXCONN) == 0 else {
            Glibc.close(socket)
            throw Self.posixError()
        }

        var boundAddress = sockaddr_in()
        var addressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddress) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Glibc.getsockname(socket, $0, &addressLength)
            }
        }
        guard nameResult == 0, boundAddress.sin_port != 0 else {
            Glibc.close(socket)
            throw Self.posixError()
        }
        self.boundPort = UInt16(bigEndian: boundAddress.sin_port)
    }

    /// Stops the server and closes accepted connections.
    public func stop() {
        let connections = state.withLock { state -> [Int32] in
            guard !state.isStopped else { return [] }
            state.isStopped = true
            defer { state.activeConnections.removeAll() }
            return [listeningSocket] + state.activeConnections
        }
        for connection in connections {
            _ = Glibc.shutdown(connection, Int32(SHUT_RDWR))
            _ = Glibc.close(connection)
        }
    }

    private func startAccepting() {
        acceptQueue.async { [weak self] in
            self?.acceptConnections()
        }
    }

    private func acceptConnections() {
        while !state.withLock(\.isStopped) {
            let connection = Glibc.accept(listeningSocket, nil, nil)
            if connection < 0 {
                if state.withLock(\.isStopped) { return }
                if errno == EINTR { continue }
                return
            }

            let shouldHandle = state.withLock { state -> Bool in
                guard !state.isStopped else { return false }
                state.activeConnections.insert(connection)
                return true
            }
            guard shouldHandle else {
                _ = Glibc.close(connection)
                return
            }

            connectionQueue.async { [weak self] in
                self?.handle(connection)
            }
        }
    }

    private func handle(_ connection: Int32) {
        defer {
            let shouldClose = state.withLock { $0.activeConnections.remove(connection) != nil }
            if shouldClose {
                _ = Glibc.shutdown(connection, Int32(SHUT_RDWR))
                _ = Glibc.close(connection)
            }
        }

        var requestData = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while !state.withLock(\.isStopped) {
            let received = buffer.withUnsafeMutableBytes {
                Glibc.recv(connection, $0.baseAddress, $0.count, 0)
            }
            if received > 0 {
                requestData.append(contentsOf: buffer.prefix(Int(received)))
                if Self.isCompleteRequest(requestData) {
                    sendResponse(on: connection, response: responseProvider(Self.parseRequest(requestData)))
                    return
                }
                continue
            }
            if received < 0, errno == EINTR { continue }
            return
        }
    }

    private func sendResponse(on connection: Int32, response: Response) {
        if let chunks = response.chunkedBody {
            let contentLength = chunks.reduce(0) { $0 + $1.count }
            guard sendAll(Self.makeHTTPResponseHeader(response: response, contentLength: contentLength), on: connection) else {
                return
            }
            for (index, chunk) in chunks.enumerated() {
                if index > 0 { Thread.sleep(forTimeInterval: response.chunkDelay) }
                guard !state.withLock(\.isStopped), sendAll(chunk, on: connection) else { return }
            }
        } else {
            _ = sendAll(Self.makeHTTPResponseData(response), on: connection)
        }
    }

    private func sendAll(_ data: Data, on connection: Int32) -> Bool {
        data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return true }
            var offset = 0
            while offset < bytes.count {
                let sent = Glibc.send(
                    connection,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset,
                    Int32(MSG_NOSIGNAL)
                )
                if sent > 0 {
                    offset += sent
                    continue
                }
                if sent < 0, errno == EINTR { continue }
                return false
            }
            return true
        }
    }

    private static func isCompleteRequest(_ data: Data) -> Bool {
        let delimiter = Data([13, 10, 13, 10])
        guard let range = data.range(of: delimiter) else { return false }
        let headerData = data[..<range.lowerBound]
        let headerText = String(data: headerData, encoding: .utf8) ?? ""
        let contentLength = headerText
            .components(separatedBy: "\r\n")
            .compactMap { line -> Int? in
                guard let colon = line.firstIndex(of: ":") else { return nil }
                let fieldName = String(line[..<colon]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard fieldName.caseInsensitiveCompare("Content-Length") == .orderedSame else { return nil }
                return Int(line[line.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines))
            }
            .first ?? 0
        return data.distance(from: range.upperBound, to: data.endIndex) >= contentLength
    }

    private static func parseRequest(_ data: Data) -> Request {
        let delimiter = Data([13, 10, 13, 10])
        let range = data.range(of: delimiter)
        let headerData = range.map { Data(data[..<$0.lowerBound]) } ?? data
        let body = range.map { Data(data[$0.upperBound...]) } ?? Data()
        let lines = String(data: headerData, encoding: .utf8)?.components(separatedBy: "\r\n") ?? []
        let requestLine = lines.first?.split(separator: " ", maxSplits: 2) ?? []
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }
        return Request(
            method: requestLine.first.map(String.init) ?? "",
            path: requestLine.dropFirst().first.map(String.init) ?? "",
            headers: headers,
            body: body
        )
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

    private static func posixError() -> Error {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
#endif
