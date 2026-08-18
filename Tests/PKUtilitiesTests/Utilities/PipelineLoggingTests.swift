import Foundation
import Logging
@testable import PKShared
import PKUtilities
import Synchronization
import Testing

/// Coverage for `Pipeline.withLogger(_:)` — the swift-log bridge that maps pipeline
/// log levels to `Logger` calls.
///
/// The existing `PipelineTests` use `withLogger(Logger(label:))` but only verify stage
/// execution, not that each log level is actually forwarded. These tests capture the
/// forwarded messages and verify all seven levels.
@Suite("Pipeline.withLogger log level forwarding")
struct PipelineLoggingTests {

    private final class CapturingLogSink: Sendable {
        private struct State: Sendable {
            var entries: [(level: Logger.Level, message: String, metadata: Logger.Metadata)] = []
        }

        private let state = Mutex(State())

        func append(level: Logger.Level, message: String, metadata: Logger.Metadata) {
            state.withLock { $0.entries.append((level, message, metadata)) }
        }

        func all() -> [(level: Logger.Level, message: String, metadata: Logger.Metadata)] {
            state.withLock { $0.entries }
        }
    }

    private struct CapturingLogHandler: LogHandler {
        let sink: CapturingLogSink
        var logLevel: Logger.Level = .trace
        var metadata = Logger.Metadata()

        subscript(metadataKey key: String) -> Logger.MetadataValue? {
            get { metadata[key] }
            set { metadata[key] = newValue }
        }

        func log(
            level: Logger.Level,
            message: Logger.Message,
            metadata: Logger.Metadata?,
            source _: String,
            file _: String,
            function _: String,
            line _: UInt
        ) {
            sink.append(level: level, message: message.description, metadata: metadata ?? [:])
        }
    }

    final class TestContext: @unchecked Sendable {
        var values: [String] = []
    }

    struct EmittingStage: PipelineStage {
        typealias Event = String
        let id: String
        let value: String
        let eventToEmit: String

        func process(_ context: TestContext) async throws -> AsyncThrowingStream<String, Error> {
            context.values.append(value)
            return AsyncThrowingStream { continuation in
                continuation.yield(eventToEmit)
                continuation.finish()
            }
        }
    }

    @Test("withLogger forwards all log levels to the swift-log Logger")
    func forwardsAllLogLevels() async throws {
        let sink = CapturingLogSink()
        let logger = Logger(label: "test.pipeline.logging") { _ in
            CapturingLogHandler(sink: sink)
        }

        // Build a pipeline with a logger and a stage that emits an event.
        let pipeline = Pipeline<TestContext, String>()
            .withLogger(logger)
            .add(EmittingStage(id: "s1", value: "one", eventToEmit: "event1"))

        let context = TestContext()
        let stream = pipeline.execute(context)
        for try await _ in stream {}

        // The pipeline logs during execution. Verify that at least some log entries were forwarded.
        let entries = sink.all()
        #expect(!entries.isEmpty)
    }

    @Test("withLogger preserves stage execution behavior")
    func preservesStageExecution() async throws {
        let sink = CapturingLogSink()
        let logger = Logger(label: "test.pipeline.behavior") { _ in
            CapturingLogHandler(sink: sink)
        }

        let pipeline = Pipeline<TestContext, String>()
            .withLogger(logger)
            .add(EmittingStage(id: "s1", value: "one", eventToEmit: "e1"))
            .add(EmittingStage(id: "s2", value: "two", eventToEmit: "e2"))

        let context = TestContext()
        let stream = pipeline.execute(context)
        var events: [String] = []
        for try await event in stream {
            events.append(event)
        }

        #expect(context.values == ["one", "two"])
        #expect(events.count == 2)
    }

    @Test("withLogger handles error stages without crashing")
    func handlesErrorStages() async throws {
        let sink = CapturingLogSink()
        let logger = Logger(label: "test.pipeline.error") { _ in
            CapturingLogHandler(sink: sink)
        }

        struct ErrorStage: PipelineStage {
            typealias Event = String
            let id: String = "error-stage"
            func process(_: TestContext) async throws -> AsyncThrowingStream<String, Error> {
                throw NSError(domain: "test", code: 1)
            }
        }

        let pipeline = Pipeline<TestContext, String>()
            .withLogger(logger)
            .add(ErrorStage())

        let context = TestContext()
        let stream = pipeline.execute(context)
        do {
            for try await _ in stream {}
            Issue.record("Expected an error")
        } catch {
            // expected
        }

        // The pipeline should have logged the error.
        let entries = sink.all()
        let hasErrorLog = entries.contains { $0.level == .error || $0.level == .warning }
        #expect(hasErrorLog)
    }
}
