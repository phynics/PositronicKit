import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
import PKUtilities

/// Package-only scripted transport shared by provider and runtime tests.
///
/// The fixture deliberately lives in `PKTestSupport` without a public access level. Provider
/// injection is package-only, so exposing this type would suggest that downstream applications
/// can construct the internal transport seams.
package actor ScriptedProviderHTTPTransport: ProviderHTTPTransport {
    package enum StreamTermination: Sendable, Equatable {
        case finish
        case failure(URLError)
    }

    package enum Response: Sendable {
        case data(Data, URLResponse)
        case lines([String], URLResponse)
        case linesUntilCancelled([String], URLResponse)
        case linesThenError([String], URLError, URLResponse)
        case error(URLError)
        case scriptedFailure(ScriptedProviderHTTPTransportError)

        package static func dataResponse(
            _ data: Data,
            statusCode: Int = 200,
            headers: [String: String] = [:]
        ) -> Response {
            .data(data, makeResponse(statusCode: statusCode, headers: headers))
        }

        package static func linesResponse(
            _ lines: [String],
            statusCode: Int = 200,
            headers: [String: String] = [:],
            termination: StreamTermination = .finish
        ) -> Response {
            .lines(lines, makeResponse(statusCode: statusCode, headers: headers))
        }

        package static func failureResponse(
            _ error: ScriptedProviderHTTPTransportError = .transportFailure
        ) -> Response {
            .scriptedFailure(error)
        }
    }

    private var responses: [Response]
    private let responder: (@Sendable (URLRequest) -> Response)?
    private var responseIndex = 0
    private var requests: [URLRequest] = []
    private var requestWaiters: [CheckedContinuation<Void, Never>] = [] // swiftlint:disable:this concurrency_stored_continuation -- actor-owned request observation waiters resume exactly once (see docs/Concurrency/exception-manifest.md)
    private var terminationWaiters: [CheckedContinuation<Void, Never>] = [] // swiftlint:disable:this concurrency_stored_continuation -- actor-owned stream termination waiters resume exactly once (see docs/Concurrency/exception-manifest.md)
    private var hasTerminated = false

    package init(responses: [Response]) {
        self.responses = responses
        self.responder = nil
    }

    package init() {
        self.init(responses: [])
    }

    package init(lines: [String], statusCode: Int = 200) {
        self.init(responses: [
            .linesResponse(
                lines,
                statusCode: statusCode,
                headers: ["Content-Type": "text/event-stream"]
            ),
        ])
    }

    package init(responder: @escaping @Sendable (URLRequest) -> Response) {
        self.responses = []
        self.responder = responder
    }

    package init(responder: @escaping @Sendable (URLRequest) -> (Data, HTTPURLResponse)) {
        self.responses = []
        self.responder = { request in
            let (data, response) = responder(request)
            return .data(data, response)
        }
    }

    package func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        record(request)
        let response = nextResponse()
        switch response {
        case let .data(data, response):
            return (data, response)
        case let .lines(lines, response):
            let data = Data(lines.joined(separator: "\n").utf8)
            return (data, response)
        case let .linesUntilCancelled(lines, response):
            return (Data(lines.joined(separator: "\n").utf8), response)
        case let .linesThenError(lines, _, response):
            return (Data(lines.joined(separator: "\n").utf8), response)
        case let .error(error):
            throw error
        case let .scriptedFailure(error):
            throw error
        }
    }

    package func lines(for request: URLRequest) async throws -> (AsyncThrowingStream<String, Error>, URLResponse) {
        record(request)
        let response = nextResponse()
        switch response {
        case let .data(data, response):
            let lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            return (makeStream(lines: lines, termination: .finish), response)
        case let .lines(lines, response):
            return (makeStream(lines: lines, termination: .finish), response)
        case let .linesUntilCancelled(lines, response):
            return (makeStream(lines: lines, termination: .finish, holdAfterLines: true), response)
        case let .linesThenError(lines, error, response):
            return (makeStream(lines: lines, termination: .failure(error)), response)
        case let .error(error):
            throw error
        case let .scriptedFailure(error):
            throw error
        }
    }

    package func recordedRequests() -> [URLRequest] {
        requests
    }

    package func lastRequest() -> URLRequest? {
        requests.last
    }

    package func requestCount() -> Int {
        requests.count
    }

    package func requestURLs() -> [URL] {
        requests.compactMap(\.url)
    }

    package func lastRequestBody() -> Data? {
        requests.last?.httpBody
    }

    /// Waits for the scripted line stream's `onTermination` callback.
    ///
    /// Tests use this to prove cancellation reached the injected transport without relying on a
    /// delay or a polling loop.
    package func waitForTermination() async {
        if hasTerminated {
            return
        }
        await withCheckedContinuation { continuation in
            terminationWaiters.append(continuation)
        }
    }

    package func waitForRequest() async {
        if !requests.isEmpty {
            return
        }
        await withCheckedContinuation { continuation in
            requestWaiters.append(continuation)
        }
    }

    private func nextResponse() -> Response {
        if let responder {
            return responder(requests.last ?? URLRequest(url: URL(string: "https://provider.test")!))
        }
        guard !responses.isEmpty else {
            return .scriptedFailure(.scriptExhausted)
        }
        let index = min(responseIndex, responses.count - 1)
        responseIndex += 1
        return responses[index]
    }

    private func makeStream(
        lines: [String],
        termination: StreamTermination,
        holdAfterLines: Bool = false
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let cancellationGate = CancellationGate()
            let producer = Task {
                for line in lines {
                    if Task.isCancelled {
                        return
                    }
                    continuation.yield(line)
                    await Task.yield()
                }

                if holdAfterLines {
                    await withTaskCancellationHandler {
                        await cancellationGate.wait()
                    } onCancel: {
                        Task { await cancellationGate.cancel() }
                    }
                }

                switch termination {
                case .finish:
                    continuation.finish()
                case let .failure(error):
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { @Sendable [weak self] _ in
                producer.cancel()
                Task { await cancellationGate.cancel() }
                guard let self else { return }
                Task { await self.recordTermination() }
            }
        }
    }

    private func recordTermination() {
        hasTerminated = true
        let waiters = terminationWaiters
        terminationWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func record(_ request: URLRequest) {
        requests.append(request)
        let waiters = requestWaiters
        requestWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private static func makeResponse(statusCode: Int, headers: [String: String]) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://provider.test")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: headers
        )!
    }
}

private actor CancellationGate {
    private var waiter: CheckedContinuation<Void, Never>? // swiftlint:disable:this concurrency_stored_continuation -- cancellation gate resumes its single waiter exactly once (see docs/Concurrency/exception-manifest.md)

    func wait() async {
        if Task.isCancelled {
            return
        }
        await withCheckedContinuation { continuation in
            if Task.isCancelled {
                continuation.resume()
            } else {
                waiter = continuation
            }
        }
    }

    func cancel() {
        waiter?.resume()
        waiter = nil
    }
}

package enum ScriptedProviderHTTPTransportError: Error, Equatable, Sendable {
    case transportFailure
    case streamFailure
    case scriptExhausted
}
