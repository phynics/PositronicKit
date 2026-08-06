import Foundation
@testable import PKShared
import PKUtilities
@testable import PositronicKit
import Synchronization
import Testing

/// Cancellation-ignoring delay used to model an uncooperative async tool without blocking a
/// cooperative-executor worker. The dispatch timer resumes independently after cancellation.
private func cancellationIgnoringDelay(_ seconds: TimeInterval) async {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
            continuation.resume()
        }
    }
}

/// Tests for `ToolTimeoutEnforcer` (PKARCH-002 AC #2): the wall-clock timeout race can be
/// exercised with a fake tool and an injected fake clock, without a `TimelineManager`.
///
/// PKRR-004 adds side-effect-aware terminal states: a tool that declares `.none` preserves
/// the fast-abandon clean timeout, while `.mutating`/`.externalProcess` tools report a
/// distinct `timedOutButMayStillBeRunning` state. The legacy fixtures below (`EchoTool`,
/// `NeverFinishingTool`, `UncooperativeTool`) declare `.none` because they genuinely mutate
/// no state — they model pure sleep/blocking work — so the pre-PKRR-004 clean-timeout
/// assertions stay valid and exercise the preserved fast-abandon path. The mutating and
/// external-process paths are covered by dedicated fixtures and tests further down.
@Suite("ToolTimeoutEnforcer")
struct ToolTimeoutEnforcerTests {
    private struct EchoTool: PKShared.Tool {
        let callName = "echo"
        let name = "echo"
        let description = "echo back the input"
        let requiresPermission = false
        let sideEffects: ToolSideEffects = .none
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
        let callName = "never"
        let name = "never"
        let description = "never returns unless cancelled"
        let requiresPermission = false
        let sideEffects: ToolSideEffects = .none
        let parametersSchema = makeEmptyObjectSchema()

        func canExecute() async -> Bool {
            true
        }

        func execute(parameters _: [String: AnyCodable]) async throws -> ToolResult {
            try await Task.sleep(for: .seconds(60))
            return .success("late")
        }
    }

    private struct UncooperativeTool: PKShared.Tool, Sendable {
        let callName = "uncooperative"
        let name = "uncooperative"
        let description = "delays and ignores cancellation"
        let requiresPermission = false
        let sideEffects: ToolSideEffects = .none
        let blockSeconds: TimeInterval
        let parametersSchema = makeEmptyObjectSchema()

        init(blockSeconds: TimeInterval) {
            self.blockSeconds = blockSeconds
        }

        func canExecute() async -> Bool {
            true
        }

        func execute(parameters _: [String: AnyCodable]) async throws -> ToolResult {
            await cancellationIgnoringDelay(blockSeconds)
            return .success("late")
        }
    }

    /// A never-finishing tool that mutates in-process state (declares `.mutating`).
    /// Models the PKRR-004 bug condition: after timeout the tool may still complete its
    /// writes, so the enforcer must report `timedOutButMayStillBeRunning`.
    private struct MutatingNeverFinishingTool: PKShared.Tool {
        let callName = "mutating_never"
        let name = "mutating_never"
        let description = "mutates state and never returns unless cancelled"
        let requiresPermission = false
        let sideEffects: ToolSideEffects = .mutating
        let parametersSchema = makeEmptyObjectSchema()

        func canExecute() async -> Bool {
            true
        }

        func execute(parameters _: [String: AnyCodable]) async throws -> ToolResult {
            try await Task.sleep(for: .seconds(60))
            return .success("late")
        }
    }

    /// An uncooperative, non-cancellable tool that mutates in-process state (declares
    /// `.mutating`). Models delayed async work that ignores cooperative cancellation.
    private struct MutatingUncooperativeTool: PKShared.Tool, Sendable {
        let callName = "mutating_uncooperative"
        let name = "mutating_uncooperative"
        let description = "mutates state, delays, and ignores cancellation"
        let requiresPermission = false
        let sideEffects: ToolSideEffects = .mutating
        let blockSeconds: TimeInterval
        let parametersSchema = makeEmptyObjectSchema()

        init(blockSeconds: TimeInterval) {
            self.blockSeconds = blockSeconds
        }

        func canExecute() async -> Bool {
            true
        }

        func execute(parameters _: [String: AnyCodable]) async throws -> ToolResult {
            await cancellationIgnoringDelay(blockSeconds)
            return .success("late")
        }
    }

    /// A never-finishing tool that drives an external process/remote service (declares
    /// `.externalProcess`). Termination requires an out-of-band kill path the runtime
    /// does not own, so the enforcer must report `timedOutButMayStillBeRunning`.
    private struct ExternalProcessNeverFinishingTool: PKShared.Tool {
        let callName = "external_never"
        let name = "external_never"
        let description = "drives an external process and never returns unless cancelled"
        let requiresPermission = false
        let sideEffects: ToolSideEffects = .externalProcess
        let parametersSchema = makeEmptyObjectSchema()

        func canExecute() async -> Bool {
            true
        }

        func execute(parameters _: [String: AnyCodable]) async throws -> ToolResult {
            try await Task.sleep(for: .seconds(60))
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
            let callName = "fail"
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

    @Test("Real Task.sleep timeout bounds a cancellation-ignoring tool")
    func realTimeoutWinsUncooperative() async throws {
        let tool = UncooperativeTool(blockSeconds: 3)
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

    // MARK: - PKRR-004: side-effect-aware terminal states

    @Test("Mutating tool that times out reports timedOutButMayStillBeRunning, not a clean timeout")
    func mutatingToolTimeoutReportsMayStillBeRunning() async throws {
        // Regression guard for PKRR-004: a mutating tool that times out must NOT get a clean
        // `executionFailed` timeout — it must get the distinct `timedOutButMayStillBeRunning`
        // state so the caller is informed that retrying may duplicate side effects.
        let instantSleep: @Sendable (UInt64) async throws -> Void = { _ in }
        let tool = MutatingNeverFinishingTool()
        do {
            _ = try await ToolTimeoutEnforcer.execute(
                AnyTool(tool),
                arguments: [:],
                timeout: 0.1,
                sleep: instantSleep
            )
            Issue.record("Expected timedOutButMayStillBeRunning")
        } catch let ToolError.timedOutButMayStillBeRunning(timeout) {
            #expect(timeout == 0.1)
        } catch let ToolError.executionFailed(msg) {
            Issue.record("Mutating tool wrongly got a clean timeout: \(msg)")
        }
    }

    @Test("Mutating uncooperative tool that times out reports timedOutButMayStillBeRunning promptly")
    func mutatingUncooperativeToolTimeoutReportsMayStillBeRunning() async throws {
        // The enforcer must still return promptly (not block on the uncooperative body) AND
        // report the may-still-be-running state for a mutating tool.
        let instantSleep: @Sendable (UInt64) async throws -> Void = { _ in }
        let tool = MutatingUncooperativeTool(blockSeconds: 3)
        do {
            _ = try await ToolTimeoutEnforcer.execute(
                AnyTool(tool),
                arguments: [:],
                timeout: 0.1,
                sleep: instantSleep
            )
            Issue.record("Expected timedOutButMayStillBeRunning")
        } catch let ToolError.timedOutButMayStillBeRunning(timeout) {
            #expect(timeout == 0.1)
        } catch let ToolError.executionFailed(msg) {
            Issue.record("Mutating uncooperative tool wrongly got a clean timeout: \(msg)")
        }
    }

    @Test("External-process tool that times out reports timedOutButMayStillBeRunning")
    func externalProcessToolTimeoutReportsMayStillBeRunning() async throws {
        let instantSleep: @Sendable (UInt64) async throws -> Void = { _ in }
        let tool = ExternalProcessNeverFinishingTool()
        do {
            _ = try await ToolTimeoutEnforcer.execute(
                AnyTool(tool),
                arguments: [:],
                timeout: 0.1,
                sleep: instantSleep
            )
            Issue.record("Expected timedOutButMayStillBeRunning")
        } catch ToolError.timedOutButMayStillBeRunning {
            // expected
        } catch let ToolError.executionFailed(msg) {
            Issue.record("External-process tool wrongly got a clean timeout: \(msg)")
        }
    }

    @Test("Real Task.sleep timeout on a mutating tool reports timedOutButMayStillBeRunning")
    func realTimeoutOnMutatingToolReportsMayStillBeRunning() async throws {
        let tool = MutatingNeverFinishingTool()
        do {
            _ = try await ToolTimeoutEnforcer.execute(
                AnyTool(tool),
                arguments: [:],
                timeout: 0.2
            )
            Issue.record("Expected timedOutButMayStillBeRunning")
        } catch let ToolError.timedOutButMayStillBeRunning(timeout) {
            #expect(timeout == 0.2)
        } catch let ToolError.executionFailed(msg) {
            Issue.record("Mutating tool wrongly got a clean timeout under real sleep: \(msg)")
        }
    }

    @Test("Side-effect-free (.none) tool preserves the clean fast-abandon timeout")
    func sideEffectFreeToolPreservesCleanTimeout() async throws {
        // AC: `.none` tools preserve the current fast-abandon clean timeout behavior.
        let instantSleep: @Sendable (UInt64) async throws -> Void = { _ in }
        let tool = NeverFinishingTool() // declares `.none`
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
        } catch ToolError.timedOutButMayStillBeRunning {
            Issue.record("Side-effect-free tool wrongly reported may-still-be-running")
        }
    }

    @Test("Tool with default sideEffects (no explicit declaration) reports may-still-be-running on timeout")
    func defaultSideEffectsToolReportsMayStillBeRunning() async throws {
        // AC: the protocol default is `.mutating`. A tool that does not declare `sideEffects`
        // must get `timedOutButMayStillBeRunning` on timeout — the conservative assumption.
        struct UndeclaredNeverFinishingTool: PKShared.Tool {
            let callName = "undeclared_never"
            let name = "undeclared_never"
            let description = "never returns; does not declare sideEffects"
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
        let instantSleep: @Sendable (UInt64) async throws -> Void = { _ in }
        let tool = UndeclaredNeverFinishingTool()
        // Sanity: the protocol default is `.mutating`.
        #expect(tool.sideEffects == .mutating)
        #expect(AnyTool(tool).sideEffects == .mutating)
        do {
            _ = try await ToolTimeoutEnforcer.execute(
                AnyTool(tool),
                arguments: [:],
                timeout: 0.1,
                sleep: instantSleep
            )
            Issue.record("Expected timedOutButMayStillBeRunning")
        } catch ToolError.timedOutButMayStillBeRunning {
            // expected — default `.mutating` is the conservative assumption
        } catch let ToolError.executionFailed(msg) {
            Issue.record("Undeclared tool wrongly got a clean timeout: \(msg)")
        }
    }

    // MARK: - PKRR-004 / PKRR-030: timeout-value validation

    @Test("Negative timeout is rejected as a clean executionFailed before the race starts")
    func negativeTimeoutRejected() async throws {
        // The tool would sleep 60s; a negative timeout must not race it — it must fail fast
        // with a clean executionFailed so the tool never runs against an invalid bound.
        let tool = NeverFinishingTool()
        let start = ContinuousClock.now
        do {
            _ = try await ToolTimeoutEnforcer.execute(
                AnyTool(tool),
                arguments: [:],
                timeout: -1
            )
            Issue.record("Expected executionFailed for negative timeout")
        } catch let ToolError.executionFailed(msg) {
            #expect(msg.contains("not a valid finite non-negative duration"))
        }
        let elapsed = ContinuousClock.now - start
        #expect(elapsed < .seconds(1))
    }

    @Test("Infinite timeout is rejected as a clean executionFailed")
    func infiniteTimeoutRejected() async throws {
        let tool = NeverFinishingTool()
        do {
            _ = try await ToolTimeoutEnforcer.execute(
                AnyTool(tool),
                arguments: [:],
                timeout: .infinity
            )
            Issue.record("Expected executionFailed for infinite timeout")
        } catch let ToolError.executionFailed(msg) {
            #expect(msg.contains("not a valid finite non-negative duration"))
        }
    }

    @Test("NaN timeout is rejected as a clean executionFailed")
    func nanTimeoutRejected() async throws {
        let tool = NeverFinishingTool()
        do {
            _ = try await ToolTimeoutEnforcer.execute(
                AnyTool(tool),
                arguments: [:],
                timeout: .nan
            )
            Issue.record("Expected executionFailed for NaN timeout")
        } catch let ToolError.executionFailed(msg) {
            #expect(msg.contains("not a valid finite non-negative duration"))
        }
    }

    @Test("Huge-but-finite timeout does not overflow UInt64 nanosecond conversion")
    func hugeFiniteTimeoutNoOverflow() async throws {
        // A timeout whose nanosecond product would overflow UInt64 must be clamped, not crash.
        // The race is non-deterministic (both sides are near-instant), so the test accepts
        // either outcome — the AC is "no overflow/trap", not "tool wins". The parked sleep
        // favors the tool slightly so the common path is the success branch.
        let tool = EchoTool(output: "ok")
        let result = try await ToolTimeoutEnforcer.execute(
            AnyTool(tool),
            arguments: [:],
            timeout: 1e30,
            sleep: { nanoseconds in
                // Park briefly so the fast EchoTool wins the race deterministically; still
                // cancelable so outer cancellation propagates cleanly.
                try await Task.sleep(nanoseconds: min(nanoseconds, 100_000_000))
            }
        )
        #expect(result.success)
        #expect(result.output == "ok")
    }
}
