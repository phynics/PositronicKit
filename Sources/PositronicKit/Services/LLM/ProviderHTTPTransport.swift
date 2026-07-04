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
            let (data, response) = try await session.data(for: request)
            let stream = AsyncThrowingStream<String, Error> { continuation in
                let task = Task {
                    do {
                        guard let text = String(data: data, encoding: .utf8) else {
                            throw NSError(domain: "ProviderHTTPTransport", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid UTF-8 in response"])
                        }
                        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
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
        #endif
    }
}
