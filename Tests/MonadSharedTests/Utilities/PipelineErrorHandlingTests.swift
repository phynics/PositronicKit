import Foundation
@testable import MonadShared
import Testing

struct PipelineErrorHandlingTests {
    final class TestContext: @unchecked Sendable {}

    struct FailingStage: PipelineStage {
        typealias Event = String
        let id: String
        let error: Error

        func process(_: TestContext) async throws -> AsyncThrowingStream<String, Error> {
            throw error
        }
    }

    struct PipelineFailingStage: PipelineStage {
        typealias Event = String
        let id: String
        let pipelineError: PipelineError

        func process(_: TestContext) async throws -> AsyncThrowingStream<String, Error> {
            throw pipelineError
        }
    }

    enum MockError: Error, LocalizedError, Equatable {
        case someError
        var errorDescription: String? {
            "Mock error"
        }
    }

    @Test("Generic Pipeline avoids double-wrapping PipelineError")
    func pipeline_avoidsDoubleWrapping() async throws {
        let innerError = PipelineError.stageFailed(id: "inner", underlyingError: MockError.someError)
        let pipeline = Pipeline<TestContext, String>()
            .add(PipelineFailingStage(id: "outer", pipelineError: innerError))

        let context = TestContext()
        do {
            let stream = pipeline.execute(context)
            for try await _ in stream {}
            Issue.record("Should have thrown")
        } catch let PipelineError.stageFailed(id, error) {
            // It should NOT be stageFailed(id: "outer", underlyingError: stageFailed(id: "inner", ...))
            // It should be the inner error itself because runStage propagates PipelineError
            #expect(id == "inner")
            #expect(error as? MockError == .someError)
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test("Pipeline cleanup error is correctly typed and not double-wrapped")
    func pipeline_cleanupErrorCorrectType() async throws {
        let pipeline = Pipeline<TestContext, String>()
            .cleanup(FailingStage(id: "clean", error: MockError.someError))

        let context = TestContext()
        do {
            let stream = pipeline.execute(context)
            for try await _ in stream {}
            Issue.record("Should have thrown")
        } catch let PipelineError.cleanupFailed(id, error) {
            #expect(id == "clean")
            #expect(error as? MockError == .someError)
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test("Primary error is prioritized over cleanup error")
    func pipeline_primaryErrorPrioritized() async throws {
        let pipeline = Pipeline<TestContext, String>()
            .add(FailingStage(id: "primary", error: MockError.someError))
            .cleanup(FailingStage(id: "cleanup", error: URLError(.notConnectedToInternet)))

        let context = TestContext()
        do {
            let stream = pipeline.execute(context)
            for try await _ in stream {}
            Issue.record("Should have thrown")
        } catch let PipelineError.stageFailed(id, error) {
            #expect(id == "primary")
            #expect(error as? MockError == .someError)
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }
}
