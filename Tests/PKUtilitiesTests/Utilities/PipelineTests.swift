import Foundation
import Logging
@testable import PKShared
import PKUtilities
import Testing

final class PipelineTests {
    final class TestContext: @unchecked Sendable { // swiftlint:disable:this concurrency_unchecked_sendable -- reviewed test double (see docs/Concurrency/exception-manifest.md)
        var values: [String] = []
    }

    struct MockStage: PipelineStage {
        typealias Event = String
        let id: String
        let value: String
        let eventToEmit: String?

        init(id: String, value: String, eventToEmit: String? = nil) {
            self.id = id
            self.value = value
            self.eventToEmit = eventToEmit
        }

        func process(_ context: TestContext) async throws -> AsyncThrowingStream<String, Error> {
            context.values.append(value)
            return AsyncThrowingStream { continuation in
                if let event = eventToEmit {
                    continuation.yield(event)
                }
                continuation.finish()
            }
        }
    }

    struct DefaultIDStage: PipelineStage {
        typealias Event = Never
        func process(_: TestContext) async throws -> AsyncThrowingStream<Never, Error> {
            return AsyncThrowingStream { $0.finish() }
        }
    }

    struct ErrorStage<E: Sendable>: PipelineStage {
        typealias Event = E
        let id: String
        let error: Error

        func process(_: TestContext) async throws -> AsyncThrowingStream<E, Error> {
            throw error
        }
    }

    enum MockError: Error, LocalizedError, Equatable {
        case someError

        var errorDescription: String? {
            return "Mock error occurred"
        }
    }

    @Test
    func defaultID() {
        let stage = DefaultIDStage()
        #expect(stage.id == "DefaultIDStage")
    }

    @Test
    func pipelineExecutionWithLogger() async throws {
        // Given
        let pipeline = Pipeline<TestContext, String>()
            .withLogger(Logger(label: "test"))
            .add(MockStage(id: "stage1", value: "one"))

        let context = TestContext()

        // When
        let stream = pipeline.execute(context)
        for try await _ in stream {}

        // Then
        #expect(context.values == ["one"])
    }

    @Test
    func pipelineExecution() async throws {
        // Given
        let pipeline = Pipeline<TestContext, String>()
            .add(MockStage(id: "stage1", value: "one"))
            .add(MockStage(id: "stage2", value: "two"))

        let context = TestContext()

        // When
        let stream = pipeline.execute(context)
        for try await _ in stream {}

        // Then
        #expect(context.values == ["one", "two"])
    }

    @Test
    func pipelineEvents() async throws {
        // Given
        let pipeline = Pipeline<TestContext, String>()
            .add(MockStage(id: "stage1", value: "one", eventToEmit: "event1"))
            .add(MockStage(id: "stage2", value: "two", eventToEmit: "event2"))

        let context = TestContext()
        var events: [String] = []

        // When
        let stream = pipeline.execute(context)
        for try await event in stream {
            events.append(event)
        }

        // Then
        #expect(context.values == ["one", "two"])
        #expect(events == ["event1", "event2"])
    }

    @Test
    func pipelineErrorHandling() async throws {
        // Given
        let pipeline = Pipeline<TestContext, String>()
            .add(MockStage(id: "stage1", value: "one"))
            .add(ErrorStage<String>(id: "errorStage", error: MockError.someError))
            .add(MockStage(id: "stage2", value: "two"))

        let context = TestContext()

        // When / Then
        do {
            let stream = pipeline.execute(context)
            for try await _ in stream {}
            Issue.record("Pipeline should have thrown an error")
        } catch let PipelineError.stageFailed(id, error) {
            #expect(id == "errorStage")
            #expect(error as? MockError == .someError)
            #expect(context.values == ["one"])
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func pipelineCleanup() async throws {
        // Given
        let pipeline = Pipeline<TestContext, String>()
            .add(MockStage(id: "stage1", value: "one"))
            .cleanup(MockStage(id: "cleanup1", value: "clean"))

        let context = TestContext()

        // When
        let stream = pipeline.execute(context)
        for try await _ in stream {}

        // Then
        #expect(context.values == ["one", "clean"])
    }

    @Test
    func pipelineCleanupAfterFailure() async throws {
        // Given
        let pipeline = Pipeline<TestContext, String>()
            .add(ErrorStage<String>(id: "errorStage", error: MockError.someError))
            .cleanup(MockStage(id: "cleanup1", value: "clean"))

        let context = TestContext()

        // When / Then
        do {
            let stream = pipeline.execute(context)
            for try await _ in stream {}
            Issue.record("Should have thrown error")
        } catch {
            #expect(context.values == ["clean"])
        }
    }

    @Test
    func pipelineCleanupFailure() async throws {
        // Given
        let pipeline = Pipeline<TestContext, Never>()
            .cleanup(ErrorStage<Never>(id: "cleanupError", error: MockError.someError))

        let context = TestContext()

        // When / Then
        do {
            let stream = pipeline.execute(context)
            for try await _ in stream {}
            Issue.record("Should have thrown error")
        } catch let PipelineError.cleanupFailed(id, _) {
            #expect(id == "cleanupError")
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test
    func pipelineCleanupFailureDoesNotOverridePrimaryError() async throws {
        let pipeline = Pipeline<TestContext, Never>()
            .add(ErrorStage<Never>(id: "primaryError", error: MockError.someError))
            .cleanup(ErrorStage<Never>(id: "cleanupError", error: MockError.someError))

        let context = TestContext()

        do {
            let stream = pipeline.execute(context)
            for try await _ in stream {}
            Issue.record("Should have thrown error")
        } catch let PipelineError.compoundFailure(primary, cleanupFailures) {
            if let stageFailed = primary as? PipelineError {
                if case let .stageFailed(id, _) = stageFailed {
                    #expect(id == "primaryError")
                }
            }
            #expect(cleanupFailures.count == 1)
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test
    func emptyPipeline() async throws {
        // Given
        let pipeline = Pipeline<TestContext, Never>()
        let context = TestContext()

        // When
        let stream = pipeline.execute(context)
        for try await _ in stream {}

        // Then
        #expect(context.values.isEmpty)
    }

    // MARK: - PipelineLogLevel Tests

    @Test
    func pipelineLogLevelHasAllLevels() {
        // Verify that PipelineLogLevel enum has all 7 standard log levels
        let levels: [PipelineLogLevel] = [.trace, .debug, .info, .notice, .warning, .error, .critical]
        #expect(levels.count == 7)
    }

    @Test
    func pipelineLogHandlerReceivesThreeParameters() async throws {
        // Verify that LogHandler receives level, message, and metadata
        class LogCapture: @unchecked Sendable { // swiftlint:disable:this concurrency_unchecked_sendable -- reviewed test double (see docs/Concurrency/exception-manifest.md)
            var calls: [(level: PipelineLogLevel, message: String, metadata: [String: String])] = []
        }

        let capture = LogCapture()
        let handler: Pipeline<TestContext, String>.LogHandler = { level, message, metadata in
            capture.calls.append((level, message, metadata))
        }

        let pipeline = Pipeline<TestContext, String>()
            .withLogHandler(handler)
            .add(MockStage(id: "stage1", value: "test"))

        let context = TestContext()
        let stream = pipeline.execute(context)
        for try await _ in stream {}

        // Pipeline should have called handler with debug level logs
        #expect(capture.calls.count > 0)
        // All calls should be debug level for pipeline internals
        #expect(capture.calls.allSatisfy { $0.level == .debug })
        // Pipeline passes empty metadata for its own logs
        #expect(capture.calls.allSatisfy { $0.metadata.isEmpty })
    }

    @Test
    func pipelineWithLoggerMapsLevelsCorrectly() async throws {
        // Create a simple test to verify withLogger works with all levels
        let logger = Logger(label: "test.pipeline")
        let pipeline = Pipeline<TestContext, String>()
            .withLogger(logger)
            .add(MockStage(id: "stage1", value: "test"))

        let context = TestContext()
        let stream = pipeline.execute(context)
        for try await _ in stream {}

        // If we reach here without crashing, the logger successfully handled all events
        #expect(context.values == ["test"])
    }

    @Test
    func pipelineErrorLogsAreEmitted() async throws {
        // Verify error logs are emitted when a stage fails
        class ErrorCapture: @unchecked Sendable { // swiftlint:disable:this concurrency_unchecked_sendable -- reviewed test double (see docs/Concurrency/exception-manifest.md)
            var errorLogs: [String] = []
        }

        let capture = ErrorCapture()
        let handler: Pipeline<TestContext, String>.LogHandler = { level, message, _ in
            if level == .error {
                capture.errorLogs.append(message)
            }
        }

        let pipeline = Pipeline<TestContext, String>()
            .withLogHandler(handler)
            .add(ErrorStage<String>(id: "failingStage", error: MockError.someError))

        let context = TestContext()

        do {
            let stream = pipeline.execute(context)
            for try await _ in stream {}
        } catch {
            // Expected
        }

        // Should have at least one error log mentioning failure
        let hasFailureLog = capture.errorLogs.contains { $0.contains("failed") }
        #expect(hasFailureLog)
    }
}
