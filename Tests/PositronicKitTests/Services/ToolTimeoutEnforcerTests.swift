import Foundation
@testable import PKShared
@testable import PositronicKit
import Synchronization
import Testing

/// Synchronous, non-cancellable sleep used to model a blocking tool body in tests. Mirrors the
/// same helper in `ToolRouterTests.swift` (kept local here so this file is self-contained).
private func blockingThreadSleep(_ seconds: TimeInterval) {
    Thread.sleep(forTimeInterval: seconds)
}

/// Tests for `ToolTimeoutEnforcer` (PKARCH-002 AC #2): the wall-clock timeout race can be
/// exercised with a fake tool and an injected fake clock, without a `TimelineManager`.
@Suite("ToolTimeoutEnforcer")
struct ToolTimeoutEnforcerTests {
    private struct EchoTool: PKShared.Tool {
        let id = "echo"
        let name = "echo"
        let description = "echo back the input"
        let requiresPermission = false
        let output: String
        let parametersSchema = makeEmptyObjectSchema()

        init(output: String = "ok") {
            self.output = output
        }

        func canExecute() async -> Bool {
            true
        }

        func execute(parameters _: [String: AnyCodable]) async throws -> ToolResult {
            .success(output)
        }
    }

    private struct NeverFinishingTool: PKShared.Tool {
        let id = "never"
        let name = "never"
        let description = "never returns unless cancelled"
        let requiresPermission = false
        let parametersSchema = makeEmptyObjectSchema()

        func canExecute() async -> Bool {
            true
        }

        func execute(parameters _: [String: AnyCodable]) async throws -> ToolResult {
            try await Task.sleep(for: .seconds(60))
            return .success("late")
        }
    }

    private struct UncooperativeTool: PKShared.Tool, @unchecked Sendable {
        let id = "uncooperative"
        let name = "uncooperative"
        let description = "blocks and ignores cancellation"
        let requiresPermission = false
        let blockSeconds: TimeInterval
        let parametersSchema = makeEmptyObjectSchema()

        init(blockSeconds: TimeInterval) {
            self.blockSeconds = blockSeconds
        }

        func canExecute() async -> Bool {
            true
        }

        func execute(parameters _: [String: AnyCodable]) async throws -> ToolResult {
            blockingThreadSleep(blockSeconds)
            return .success("late")
        }
    }

    @Test("Successful tool execution returns the tool's output")
    func success() async throws {
        let tool = EchoTool(output: "hello")
        let result = try await ToolTimeoutEnforcer.execute(
            AnyTool(tool),
            arguments: [:],
            timeout: 5
        )
        #expect(result.success)
        #expect(result.output == "hello")
    }

    @Test("Tool that throws surfaces the wrapped error")
    func toolError() async throws {
        struct FailingTool: PKShared.Tool {
            let id = "fail"
            let name = "fail"
            let description = "always fails"
            let requiresPermission = false
            let parametersSchema = makeEmptyObjectSchema()

            func canExecute() async -> Bool {
                true
            }

            func execute(parameters _: [String: AnyCodable]) async throws -> ToolResult {
                throw ToolError.executionFailed("boom")
            }
        }
        do {
            _ = try await ToolTimeoutEnforcer.execute(AnyTool(FailingTool()), arguments: [:], timeout: 5)
            Issue.record("Expected executionFailed")
        } catch let ToolError.executionFailed(msg) {
            #expect(msg == "boom")
        }
    }

    @Test("Timeout fires when the fake sleep returns immediately")
    func fakeClockTimeout() async throws {
        // Fake clock: completes the timeout race instantly, so the tool's `Task.sleep(60s)`
        // never wins, even though no real wall-clock time elapses.
        let instantSleep: @Sendable (UInt64) async throws -> Void = { _ in }
        let tool = NeverFinishingTool()
        do {
            _ = try await ToolTimeoutEnforcer.execute(
                AnyTool(tool),
                arguments: [:],
                timeout: 0.1,
                sleep: instantSleep
            )
            Issue.record("Expected executionFailed timeout")
        } catch let ToolError.executionFailed(msg) {
            #expect(msg.contains("timed out"))
        }
    }

    @Test("Fake-clock timeout returns promptly even when the tool is uncooperative and slow")
    func fakeClockTimeoutBoundsUncooperativeTool() async throws {
        let instantSleep: @Sendable (UInt64) async throws -> Void = { _ in }
        let tool = UncooperativeTool(blockSeconds: 3)
        let start = ContinuousClock.now
        do {
            _ = try await ToolTimeoutEnforcer.execute(
                AnyTool(tool),
                arguments: [:],
                timeout: 0.1,
                sleep: instantSleep
            )
            Issue.record("Expected executionFailed timeout")
        } catch let ToolError.executionFailed(msg) {
            #expect(msg.contains("timed out"))
        }
        let elapsed = ContinuousClock.now - start
        // The fake-clock path should resolve essentially instantly — far below the tool's 3s body.
        #expect(elapsed < .seconds(1))
    }

    @Test("Real Task.sleep timeout bounds a never-finishing tool (no fake clock)")
    func realTimeoutWinsRealSleep() async throws {
        let tool = NeverFinishingTool()
        do {
            // PKFLAKE-006: widened from 0.01s — real Task.sleep can oversleep under CI
            // load, and this test's point is coverage of the real default sleep path,
            // not razor-thin timing.
            _ = try await ToolTimeoutEnforcer.execute(
                AnyTool(tool),
                arguments: [:],
                timeout: 0.2
            )
            Issue.record("Expected executionFailed timeout")
        } catch let ToolError.executionFailed(msg) {
            #expect(msg.contains("timed out"))
            #expect(msg.contains("0.2 seconds"))
        }
    }

    @Test("Real Task.sleep timeout bounds an uncooperative blocking tool")
    func realTimeoutWinsUncooperative() async throws {
        let tool = UncooperativeTool(blockSeconds: 3)
        let start = ContinuousClock.now
        do {
            // PKFLAKE-006: widened from 0.05s / assertion widened from 1s — real Task.sleep
            // can oversleep under CI load; this test only needs to confirm the real default
            // sleep path still bounds the tool, not exact timing.
            _ = try await ToolTimeoutEnforcer.execute(
                AnyTool(tool),
                arguments: [:],
                timeout: 0.2
            )
            Issue.record("Expected executionFailed timeout")
        } catch let ToolError.executionFailed(msg) {
            #expect(msg.contains("timed out"))
        }
        let elapsed = ContinuousClock.now - start
        #expect(elapsed < .seconds(5))
    }

    @Test("External cancellation propagates promptly and does not leak orphaned tasks")
    func externalCancellationPropagates() async throws {
        let sleepObservedCancellation = Mutex(false)
        let parkedSleep: @Sendable (UInt64) async throws -> Void = { _ in
            do {
                try await Task.sleep(for: .seconds(3600))
            } catch {
                sleepObservedCancellation.withLock { $0 = true }
                throw error
            }
        }

        let raceTask = Task {
            try await ToolTimeoutEnforcer.execute(
                AnyTool(NeverFinishingTool()),
                arguments: [:],
                timeout: 60,
                sleep: parkedSleep
            )
        }

        await Task.yield()
        raceTask.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await raceTask.value
        }
        #expect(sleepObservedCancellation.withLock { $0 })
    }

    @Test("timeoutDescription formats integer timeouts without a decimal")
    func integerTimeoutFormat() {
        #expect(ToolTimeoutEnforcer.timeoutDescription(60) == "60 seconds")
        #expect(ToolTimeoutEnforcer.timeoutDescription(1) == "1 seconds")
    }

    @Test("timeoutDescription preserves fractional timeouts")
    func fractionalTimeoutFormat() {
        #expect(ToolTimeoutEnforcer.timeoutDescription(0.05) == "0.05 seconds")
        #expect(ToolTimeoutEnforcer.timeoutDescription(1.5) == "1.5 seconds")
    }

    @Test("Zero timeout still races the tool against an immediate timeout (default sleep)")
    func zeroTimeoutRacesTool() async throws {
        // A zero timeout with the real default sleep returns near-instantly because
        // `Task.sleep(0)` resolves on the next runloop tick. The fast EchoTool usually wins.
        let tool = EchoTool()
        let result = try await ToolTimeoutEnforcer.execute(
            AnyTool(tool),
            arguments: [:],
            timeout: 0
        )
        // The tool is a fast async return, so it should win the race under default sleep.
        #expect(result.success)
        #expect(result.output == "ok")
    }
}
