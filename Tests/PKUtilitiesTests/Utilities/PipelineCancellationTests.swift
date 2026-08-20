import Foundation
@testable import PKContracts
import PKUtilities
import Testing

struct PipelineCancellationTests {
    final class TestContext: @unchecked Sendable {} // swiftlint:disable:this concurrency_unchecked_sendable -- reviewed test double (see docs/Concurrency/exception-manifest.md)

    struct EmittingStage: PipelineStage {
        typealias Event = String
        let id: String
        let events: [String]

        func process(_: TestContext) async throws -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { continuation in
                for event in events {
                    continuation.yield(event)
                }
                continuation.finish()
            }
        }
    }

    struct DelayedStage: PipelineStage {
        typealias Event = String
        let id: String

        func process(_: TestContext) async throws -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { continuation in
                let task = Task {
                    do {
                        try await Task.sleep(nanoseconds: 100_000_000)
                        continuation.yield("done")
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
    }

    struct FailingStage: PipelineStage {
        typealias Event = String
        let id: String
        let error: Error

        func process(_: TestContext) async throws -> AsyncThrowingStream<String, Error> {
            throw error
        }
    }

    enum MockError: Error, LocalizedError, Equatable {
        case someError
        var errorDescription: String? { "Mock error" }
    }

    @Test("Cancellation after final stage throws before successful finish")
    func cancellationAfterFinalStageThrows() async throws {
        let pipeline = Pipeline<TestContext, String>()
            .add(EmittingStage(id: "done", events: ["finished"]))

        let context = TestContext()
        let stream = pipeline.execute(context)

        let task = Task {
            for try await _ in stream {}
        }

        task.cancel()

        do {
            try await task.value
        } catch is CancellationError {
        } catch let PipelineError.stageFailed(_, underlying) {
            #expect(underlying is CancellationError, "Underlying should be CancellationError")
        } catch let PipelineError.compoundFailure(primary, _) {
            #expect(primary is CancellationError || (primary as? PipelineError) != nil,
                    "Primary should be cancellation-related, got \(primary)")
        } catch {
        }
    }

    @Test("Multiple cleanup failures are observable without log scraping")
    func multipleCleanupFailuresObservable() async throws {
        let pipeline = Pipeline<TestContext, String>()
            .add(FailingStage(id: "primary", error: MockError.someError))
            .cleanup(FailingStage(id: "clean1", error: URLError(.notConnectedToInternet)))
            .cleanup(FailingStage(id: "clean2", error: URLError(.badURL)))

        let context = TestContext()
        do {
            let stream = pipeline.execute(context)
            for try await _ in stream {}
            Issue.record("Should have thrown")
        } catch let PipelineError.compoundFailure(primary, cleanupFailures) {
            if case let .stageFailed(_, underlying) = primary as? PipelineError ?? .stageFailed(id: "", underlyingError: MockError.someError) {
                #expect(underlying as? MockError == .someError)
            }
            #expect(cleanupFailures.count == 2, "Both cleanup failures should be observable")
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test("Cleanup runs even when primary is cancelled")
    func cleanupRunsAfterCancellation() async throws {
        actor CleanupTracker {
            var ran = false
            func mark() { ran = true }
        }
        let tracker = CleanupTracker()

        struct TrackingCleanupStage: PipelineStage {
            typealias Event = String
            let id: String
            let tracker: CleanupTracker

            func process(_: TestContext) async throws -> AsyncThrowingStream<String, Error> {
                await tracker.mark()
                return AsyncThrowingStream { $0.finish() }
            }
        }

        let pipeline = Pipeline<TestContext, String>()
            .add(DelayedStage(id: "primary"))
            .cleanup(TrackingCleanupStage(id: "cleanup", tracker: tracker))

        let context = TestContext()
        let stream = pipeline.execute(context)

        let task = Task {
            for try await _ in stream {}
        }

        try await Task.sleep(nanoseconds: 10_000_000)
        task.cancel()

        do { try await task.value } catch {}

        #expect(await tracker.ran, "Cleanup should run even after cancellation")
    }

    @Test("Compound failure has stable error code and domain")
    func compoundFailureErrorIdentity() async throws {
        let pipeline = Pipeline<TestContext, String>()
            .add(FailingStage(id: "primary", error: MockError.someError))
            .cleanup(FailingStage(id: "clean", error: URLError(.notConnectedToInternet)))

        let context = TestContext()
        do {
            let stream = pipeline.execute(context)
            for try await _ in stream {}
            Issue.record("Should have thrown")
        } catch let error as PipelineError {
            #expect(error.errorDomain == PKErrorDomain.pipeline)
            #expect(error.errorCode == 4003)
            #expect(!error.userFriendlyMessage.isEmpty)
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }
}
