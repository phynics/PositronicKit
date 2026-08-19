import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
import Synchronization

package protocol ProviderHTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
    func lines(for request: URLRequest) async throws -> (AsyncThrowingStream<String, Error>, URLResponse)
}

package struct URLSessionProviderHTTPTransport: ProviderHTTPTransport {
    private let session: URLSession

    package init(timeoutIntervalForRequest: TimeInterval, timeoutIntervalForResource: TimeInterval? = nil, waitsForConnectivity: Bool = false) {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = timeoutIntervalForRequest
        if let timeoutIntervalForResource {
            configuration.timeoutIntervalForResource = timeoutIntervalForResource
        }
        #if os(iOS) || os(macOS) || os(tvOS) || os(watchOS)
            configuration.waitsForConnectivity = waitsForConnectivity
        #endif
        session = URLSession(configuration: configuration)
    }

    package init(session: URLSession) {
        self.session = session
    }

    package func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }

    package func lines(for request: URLRequest) async throws -> (AsyncThrowingStream<String, Error>, URLResponse) {
        #if os(iOS) || os(macOS) || os(tvOS) || os(watchOS)
            let (bytes, response) = try await session.bytes(for: request)
            let stream = AsyncThrowingStream<String, Error> { continuation in
                let task = Task {
                    do {
                        for try await line in bytes.lines {
                            if Task.isCancelled {
                                continuation.finish(throwing: CancellationError())
                                return
                            }
                            continuation.yield(line)
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }

                continuation.onTermination = { @Sendable _ in
                    task.cancel()
                }
            }
            return (stream, response)
        #else
            return try await streamingLinesViaDelegate(for: request)
        #endif
    }

    #if !(os(iOS) || os(macOS) || os(tvOS) || os(watchOS))
    /// Linux/corelibs-foundation: `URLSession.bytes(for:)` is not available, so
    /// incremental streaming is implemented via a `URLSessionDataDelegate` that
    /// yields lines as data chunks arrive rather than buffering the full body.
    private func streamingLinesViaDelegate(
        for request: URLRequest
    ) async throws -> (AsyncThrowingStream<String, Error>, URLResponse) {
        let coordinator = StreamingLineCoordinator()
        let streamingSession = URLSession(
            configuration: session.configuration,
            delegate: StreamingLineDelegate(coordinator: coordinator),
            delegateQueue: nil
        )
        let task = streamingSession.dataTask(with: request)
        task.resume()

        let response: URLResponse
        do {
            response = try await withTaskCancellationHandler {
                let response = try await coordinator.awaitResponse()
                try Task.checkCancellation()
                return response
            } onCancel: {
                coordinator.cancelResponseWait()
                task.cancel()
                streamingSession.invalidateAndCancel()
            }
        } catch {
            task.cancel()
            streamingSession.invalidateAndCancel()
            throw error
        }

        let stream = AsyncThrowingStream<String, Error> { continuation in
            coordinator.attachLineContinuation(continuation)
            continuation.onTermination = { @Sendable _ in
                task.cancel()
                streamingSession.finishTasksAndInvalidate()
            }
        }

        return (stream, response)
    }
    #endif
}

#if !(os(iOS) || os(macOS) || os(tvOS) || os(watchOS))
/// Lifecycle state for the Linux streaming bridge. Every field is owned by the
/// `StreamingLineCoordinator` mutex; the two continuation claims (one-shot
/// pre-stream response, one-shot line-stream attachment) are the sanctioned
/// explicit lifecycle state machine (see docs/Concurrency/exception-manifest.md).
private struct StreamingLineState {
    var capturedResponse: URLResponse?
    var buffer = Data()
    var didFinish = false
    var finishError: Error?
    var responseContinuation: CheckedContinuation<URLResponse, Error>? // swiftlint:disable:this concurrency_stored_continuation -- explicit Mutex-owned lifecycle state machine (see docs/Concurrency/exception-manifest.md)
    var lineContinuation: AsyncThrowingStream<String, Error>.Continuation? // swiftlint:disable:this concurrency_stored_continuation -- explicit Mutex-owned lifecycle state machine (see docs/Concurrency/exception-manifest.md)

    /// Yields complete lines and drops the trailing partial line. Call only
    /// while the coordinator holds the mutex.
    mutating func splitCompleteLines() -> [String] {
        var lines: [String] = []
        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<newlineIndex]
            buffer.removeSubrange(buffer.startIndex...newlineIndex)
            if let line = String(data: lineData, encoding: .utf8) {
                lines.append(line)
            }
        }
        return lines
    }

    /// Returns and clears any remaining unterminated buffer content. Call only
    /// while the coordinator holds the mutex.
    mutating func extractRemaining() -> String? {
        guard !buffer.isEmpty else { return nil }
        let remaining = buffer
        buffer.removeAll()
        return String(data: remaining, encoding: .utf8)
    }
}

/// Owns the one-shot `URLSession` streaming-request lifecycle. All mutations
/// happen through `Mutex<StreamingLineState>`; continuations are claimed inside
/// the critical section and always resumed *outside* it so a resumer can never
/// re-enter the lock. The URLSession delegate queue is the only producer besides
/// the async caller and cancellation path.
private final class StreamingLineCoordinator: Sendable {
    private let state = Mutex(StreamingLineState())

    func awaitResponse() async throws -> URLResponse {
        try await withCheckedThrowingContinuation { continuation in
            let immediate = state.withLock { current -> (URLResponse?, Error?) in
                if let response = current.capturedResponse {
                    return (response, nil)
                }
                if let error = current.finishError {
                    return (nil, error)
                }
                current.responseContinuation = continuation
                return (nil, nil)
            }
            if let response = immediate.0 {
                continuation.resume(returning: response)
            } else if let error = immediate.1 {
                continuation.resume(throwing: error)
            }
        }
    }

    /// Fails a pending pre-stream response wait. Cancellation and response
    /// delivery race to claim the continuation under the mutex, so it is
    /// resumed exactly once.
    func cancelResponseWait() {
        let pending = state.withLock { current -> CheckedContinuation<URLResponse, Error>? in
            guard current.capturedResponse == nil else { return nil }
            current.didFinish = true
            current.finishError = CancellationError()
            let continuation = current.responseContinuation
            current.responseContinuation = nil
            return continuation
        }
        pending?.resume(throwing: CancellationError())
    }

    func attachLineContinuation(_ continuation: AsyncThrowingStream<String, Error>.Continuation) {
        let deliver = state.withLock { current -> (lines: [String], remaining: String?, shouldFinish: Bool, error: Error?) in
            current.lineContinuation = continuation
            let lines = current.splitCompleteLines()
            var remaining: String?
            var shouldFinish = false
            var error: Error?
            if current.didFinish {
                remaining = current.extractRemaining()
                shouldFinish = true
                error = current.finishError
                current.lineContinuation = nil
            }
            return (lines, remaining, shouldFinish, error)
        }

        for line in deliver.lines {
            continuation.yield(line)
        }
        if let remaining = deliver.remaining {
            continuation.yield(remaining)
        }
        if deliver.shouldFinish {
            if let error = deliver.error {
                continuation.finish(throwing: error)
            } else {
                continuation.finish()
            }
        }
    }

    func didReceive(response: URLResponse) {
        let pending = state.withLock { current -> CheckedContinuation<URLResponse, Error>? in
            current.capturedResponse = response
            let continuation = current.responseContinuation
            current.responseContinuation = nil
            return continuation
        }
        pending?.resume(returning: response)
    }

    func didReceive(data: Data) {
        let deliver = state.withLock { current -> (continuation: AsyncThrowingStream<String, Error>.Continuation?, lines: [String]) in
            current.buffer.append(data)
            guard let continuation = current.lineContinuation else {
                return (nil, [])
            }
            return (continuation, current.splitCompleteLines())
        }

        guard let continuation = deliver.continuation else { return }
        for line in deliver.lines {
            continuation.yield(line)
        }
    }

    func didCompleteWithError(_ error: Error?) {
        let deliver = state.withLock { current -> (continuation: CheckedContinuation<URLResponse, Error>?, error: Error?) in
            current.finishError = error
            current.didFinish = true

            if current.capturedResponse == nil {
                let continuation = current.responseContinuation
                current.responseContinuation = nil
                return (continuation, error)
            }
            return (nil, nil)
        }
        if let continuation = deliver.continuation {
            if let error = deliver.error {
                continuation.resume(throwing: error)
            } else {
                continuation.resume(throwing: URLError(.unknown))
            }
            return
        }

        let lineDeliver = state.withLock { current -> (continuation: AsyncThrowingStream<String, Error>.Continuation?, remaining: String?, error: Error?) in
            guard let continuation = current.lineContinuation else {
                return (nil, nil, nil)
            }
            let remaining = current.extractRemaining()
            current.lineContinuation = nil
            return (continuation, remaining, current.finishError)
        }

        guard let continuation = lineDeliver.continuation else { return }
        if let remaining = lineDeliver.remaining {
            continuation.yield(remaining)
        }
        if let error = lineDeliver.error {
            continuation.finish(throwing: error)
        } else {
            continuation.finish()
        }
    }
}

/// Thin `URLSessionDataDelegate` shell whose only job is to forward Foundation
/// callback traffic onto the mutex-owned coordinator. The coordinator serializes
/// everything; the delegate holds no mutable state and needs no `Sendable`
/// conformance of its own because it is confined to the URLSession it belongs to.
private final class StreamingLineDelegate: NSObject, URLSessionDataDelegate {
    private let coordinator: StreamingLineCoordinator

    init(coordinator: StreamingLineCoordinator) {
        self.coordinator = coordinator
        super.init()
    }

    // MARK: - URLSessionDataDelegate

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        coordinator.didReceive(response: response)
        completionHandler(.allow)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        coordinator.didReceive(data: data)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        coordinator.didCompleteWithError(error)
    }
}
#endif
