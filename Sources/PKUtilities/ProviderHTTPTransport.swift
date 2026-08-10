import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

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
        let delegate = StreamingLineDelegate()
        let streamingSession = URLSession(
            configuration: session.configuration,
            delegate: delegate,
            delegateQueue: nil
        )
        let task = streamingSession.dataTask(with: request)
        task.resume()

        let response: URLResponse
        do {
            response = try await withTaskCancellationHandler {
                let response = try await delegate.awaitResponse()
                try Task.checkCancellation()
                return response
            } onCancel: {
                delegate.cancelResponseWait()
                task.cancel()
                streamingSession.invalidateAndCancel()
            }
        } catch {
            task.cancel()
            streamingSession.invalidateAndCancel()
            throw error
        }

        let stream = AsyncThrowingStream<String, Error> { continuation in
            delegate.attachLineContinuation(continuation)
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
/// `URLSessionDataDelegate` that bridges incremental data delivery to an
/// `AsyncThrowingStream<String, Error>`, yielding complete lines as chunks
/// arrive instead of waiting for the full response body.
///
/// Thread safety: all delegate callbacks are dispatched on the session's
/// serial `delegateQueue`. The `lock` protects shared state (buffer,
/// continuations) against concurrent access from the async caller.
private final class StreamingLineDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var lineContinuation: AsyncThrowingStream<String, Error>.Continuation?
    private var responseContinuation: CheckedContinuation<URLResponse, Error>?
    private var capturedResponse: URLResponse?
    private var buffer = Data()
    private var didFinish = false
    private var finishError: Error?

    func awaitResponse() async throws -> URLResponse {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let response = capturedResponse {
                lock.unlock()
                continuation.resume(returning: response)
            } else if let error = finishError {
                lock.unlock()
                continuation.resume(throwing: error)
            } else {
                responseContinuation = continuation
                lock.unlock()
            }
        }
    }

    /// Fails a pending pre-stream response wait. The lock makes cancellation and
    /// response delivery race to claim the continuation, so it is resumed once.
    func cancelResponseWait() {
        lock.lock()
        guard capturedResponse == nil else {
            lock.unlock()
            return
        }

        didFinish = true
        finishError = CancellationError()
        let continuation = responseContinuation
        responseContinuation = nil
        lock.unlock()

        continuation?.resume(throwing: CancellationError())
    }

    func attachLineContinuation(_ continuation: AsyncThrowingStream<String, Error>.Continuation) {
        lock.lock()
        lineContinuation = continuation
        let lines = splitCompleteLinesLocked()
        var remaining: String? = nil
        var shouldFinish = false
        var error: Error? = nil
        if didFinish {
            remaining = extractRemainingLocked()
            shouldFinish = true
            error = finishError
            lineContinuation = nil
        }
        lock.unlock()

        for line in lines {
            continuation.yield(line)
        }
        if let remaining {
            continuation.yield(remaining)
        }
        if shouldFinish {
            if let error {
                continuation.finish(throwing: error)
            } else {
                continuation.finish()
            }
        }
    }

    // MARK: - URLSessionDataDelegate

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        lock.lock()
        capturedResponse = response
        let cont = responseContinuation
        responseContinuation = nil
        lock.unlock()
        cont?.resume(returning: response)
        completionHandler(.allow)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        lock.lock()
        buffer.append(data)
        let cont = lineContinuation
        let lines: [String] = cont != nil ? splitCompleteLinesLocked() : []
        lock.unlock()
        for line in lines {
            cont?.yield(line)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        lock.lock()
        finishError = error
        didFinish = true

        if capturedResponse == nil {
            let respCont = responseContinuation
            responseContinuation = nil
            lock.unlock()
            if let error {
                respCont?.resume(throwing: error)
            } else {
                respCont?.resume(throwing: URLError(.unknown))
            }
            return
        }

        let cont = lineContinuation
        if cont != nil {
            let remaining = extractRemainingLocked()
            lineContinuation = nil
            lock.unlock()
            if let remaining {
                cont?.yield(remaining)
            }
            if let error {
                cont?.finish(throwing: error)
            } else {
                cont?.finish()
            }
        } else {
            lock.unlock()
        }
    }

    // MARK: - Line splitting (must be called while holding lock)

    private func splitCompleteLinesLocked() -> [String] {
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

    private func extractRemainingLocked() -> String? {
        guard !buffer.isEmpty else { return nil }
        let remaining = buffer
        buffer.removeAll()
        return String(data: remaining, encoding: .utf8)
    }
}
#endif
