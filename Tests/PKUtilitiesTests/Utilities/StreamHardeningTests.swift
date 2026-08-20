import Foundation
@testable import PKContracts
import PKUtilities
import Synchronization
import Testing

@Suite("Stream hardening utilities")
struct StreamHardeningTests {
    @Test("Cancellable stream cancels producer task on termination")
    func cancellableStreamCancelsProducerTaskOnTermination() async throws {
        let didCancel = Mutex(false)
        let stream = CancellableAsyncThrowingStream.make(of: Int.self) { continuation in
            await withTaskCancellationHandler {
                try? await Task.sleep(for: .seconds(60))
                continuation.finish()
            } onCancel: {
                didCancel.withLock { $0 = true }
            }
        }

        let consumer = Task {
            for try await _ in stream {}
        }

        consumer.cancel()

        for _ in 0 ..< 50 where !didCancel.withLock({ $0 }) {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(didCancel.withLock { $0 })
    }

    @Test("Limited error body collector caps long bodies")
    func limitedErrorBodyCollectorCapsLongBodies() async throws {
        let stream = AsyncStream<String> { continuation in
            continuation.yield(String(repeating: "a", count: 9_000))
            continuation.finish()
        }

        let body = try await LimitedErrorBodyCollector.collect(from: stream)

        #expect(body.count == LimitedErrorBodyCollector.defaultLimit)
        #expect(body == String(repeating: "a", count: LimitedErrorBodyCollector.defaultLimit))
    }
}
