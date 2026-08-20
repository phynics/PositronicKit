import Foundation
@testable import PKContracts
import PKUtilities
@testable import PositronicKit
import Synchronization
import Testing

/// A one-shot asynchronous latch. Waiting uses a continuation, so task cancellation does not
/// resume a waiter; `open()` deterministically resumes every current and future waiter.
private final class AsyncLatch: Sendable {
    private enum State: Sendable {
        case closed([CheckedContinuation<Void, Never>])
        case open
    }

    private let state = Mutex<State>(.closed([]))

    var isOpen: Bool {
        state.withLock { state in
            if case .open = state {
                return true
            }
            return false
        }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            let resumeImmediately = state.withLock { state in
                switch state {
                case var .closed(waiters):
                    waiters.append(continuation)
                    state = .closed(waiters)
                    return false
                case .open:
                    return true
                }
            }

            if resumeImmediately {
                continuation.resume()
            }
        }
    }

    func open() {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            switch state {
            case let .closed(waiters):
                state = .open
                return waiters
            case .open:
                return []
            }
        }

        for waiter in waiters {
            waiter.resume()
        }
    }
}

/// Tests for `ToolTimeoutEnforcer` (PKARCH-002 AC #2): the wall-clock timeout race can be
/// exercised with a fake tool and an injected fake clock, without a `ThreadManager`.
///
/// PKRR-004 adds side-effect-aware terminal states: a tool that declares `.none` preserves
/// the fast-abandon clean timeout, while `.mutating`/`.externalProcess` tools report a
/// distinct `timedOutButMayStillBeRunning` state. The legacy fixtures below (`EchoTool`,
/// `NeverFinishingTool`, `ControlledUncooperativeTool`) declare `.none` because they genuinely
/// mutate no state — they model pure suspended work — so the pre-PKRR-004 clean-timeout
/// assertions stay valid and exercise the preserved fast-abandon path. The mutating and
/// external-process paths are covered by dedicated fixtures and tests further down.
@Suite("ToolTimeoutEnforcer")
struct ToolTimeoutEnforcerTests {
    private struct EchoTool: PKContracts.Tool {
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

    private struct NeverFinishingTool: PKContracts.Tool {
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

    private struct ControlledUncooperativeTool: PKContracts.Tool, Sendable {
        let callName = "controlled_uncooperative"
        let name = "controlled_uncooperative"
        let description = "suspends asynchronously and ignores cancellation"
        let requiresPermission = false
        let sideEffects: ToolSideEffects
        let started: AsyncLatch
        let release: AsyncLatch
        let parametersSchema = makeEmptyObjectSchema()

        func canExecute() async -> Bool {
            true
        }

        func execute(parameters _: [String: AnyCodable]) async throws -> ToolResult {
            started.open()
            await release.wait()
            return .success("late")
        }
    }

    /// A never-finishing tool that mutates in-process state (declares `.mutating`).
    /// Models the PKRR-004 bug condition: after timeout the tool may still complete its
    /// writes, so the enforcer must report `timedOutButMayStillBeRunning`.
    private struct MutatingNeverFinishingTool: PKContracts.Tool {
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

    /// A never-finishing tool that drives an external process/remote service (declares
    /// `.externalProcess`). Termination requires an out-of-band kill path the runtime
    /// does not own, so the enforcer must report `timedOutButMayStillBeRunning`.
    private struct ExternalProcessNeverFinishingTool: PKContracts.Tool {
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
        struct FailingTool: PKContracts.Tool {
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

    @Test("Fake-clock timeout abandons a cancellation-ignoring asynchronous tool")
    func fakeClockTimeoutBoundsUncooperativeTool() async throws {
        let started = AsyncLatch()
        let release = AsyncLatch()
        defer { release.open() }

        let timeoutAfterToolStarts: @Sendable (UInt64) async throws -> Void = { _ in
            await started.wait()
        }
        let tool = ControlledUncooperativeTool(
            sideEffects: .none,
            started: started,
            release: release
        )
        do {
            _ = try await ToolTimeoutEnforcer.execute(
                AnyTool(tool),
                arguments: [:],
                timeout: 0.1,
                sleep: timeoutAfterToolStarts
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

    @Test("Mutating cancellation-ignoring tool reports timedOutButMayStillBeRunning")
    func mutatingCancellationIgnoringToolReportsMayStillBeRunning() async throws {
        // The timeout starts only after the tool is suspended, then reports the
        // may-still-be-running state without relying on timing assertions.
        let started = AsyncLatch()
        let release = AsyncLatch()
        defer { release.open() }

        let timeoutAfterToolStarts: @Sendable (UInt64) async throws -> Void = { _ in
            await started.wait()
        }
        let tool = ControlledUncooperativeTool(
            sideEffects: .mutating,
            started: started,
            release: release
        )
        do {
            _ = try await ToolTimeoutEnforcer.execute(
                AnyTool(tool),
                arguments: [:],
                timeout: 0.1,
                sleep: timeoutAfterToolStarts
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
        struct UndeclaredNeverFinishingTool: PKContracts.Tool {
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
        // A negative timeout must fail validation before the tool task starts.
        let started = AsyncLatch()
        let release = AsyncLatch()
        defer { release.open() }
        let tool = ControlledUncooperativeTool(
            sideEffects: .none,
            started: started,
            release: release
        )
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
        #expect(started.isOpen == false)
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
