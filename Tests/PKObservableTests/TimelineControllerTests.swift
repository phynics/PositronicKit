import Foundation
import PKObservable
import PKTestSupport
import PositronicKit
import Testing

@Suite("Timeline controller")
@MainActor
struct TimelineControllerTests {
    @Test("mirrors streamed text and completed messages")
    func mirrorsStreamedTextAndCompletedMessages() async throws {
        let runtime = TestRuntime(workspaceRoot: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString))
        runtime.llm.mockClient.nextChunks = [["Hello, ", "world!"]]
        let kit = runtime.runtime
        let driver = try await kit.timelines.create(title: "Controller")
        let agent = try await kit.agents.create(name: "Controller Agent", description: "test")
        try await kit.agents.attach(agent.id, to: driver.id)
        let controller = TimelineController(driver)

        try await controller.send("Hi")

        #expect(controller.isStreaming == false)
        #expect(controller.streamingText.isEmpty)
        #expect(controller.messages.map(\.content) == ["Hi", "Hello, world!"])
    }

    @Test("a completed send clears its active task")
    func completedSendClearsActiveTask() async throws {
        let runtime = TestRuntime(workspaceRoot: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString))
        runtime.llm.mockClient.nextResponses = ["reply"]
        let kit = runtime.runtime
        let driver = try await kit.timelines.create(title: "Controller")
        let agent = try await kit.agents.create(name: "Controller Agent", description: "test")
        try await kit.agents.attach(agent.id, to: driver.id)
        var controller: TimelineController? = TimelineController(driver)
        weak var releasedController: TimelineController? = nil
        releasedController = controller

        try await controller!.send("Hi")
        controller = nil
        await Task.yield()

        #expect(releasedController == nil)
    }

    @Test("a provider failure is thrown with its terminal event and clears state")
    func providerFailurePropagatesAsControllerError() async throws {
        let runtime = TestRuntime(workspaceRoot: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString))
        runtime.llm.mockClient.shouldThrowError = true
        let kit = runtime.runtime
        let driver = try await kit.timelines.create(title: "Controller")
        let agent = try await kit.agents.create(name: "Controller Agent", description: "test")
        try await kit.agents.attach(agent.id, to: driver.id)
        let controller = TimelineController(driver)

        let error = await #expect(throws: TimelineControllerError.self) {
            try await controller.send("Hi")
        }

        #expect(controller.isStreaming == false)
        #expect(controller.streamingText.isEmpty)
        if let event = error?.event, case .error = event {
            // The provider/runtime failure remains distinguishable from cancellation.
        } else {
            Issue.record("Expected the controller error to carry a general runtime error event")
        }
    }

    @Test("cancellation is thrown as CancellationError and clears state")
    func cancellationPropagatesAsCancellationError() async throws {
        let runtime = TestRuntime(workspaceRoot: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString))
        runtime.llm.mockClient.neverFinishingStreamCallIndices = [1]
        let kit = runtime.runtime
        let driver = try await kit.timelines.create(title: "Controller")
        let agent = try await kit.agents.create(name: "Controller Agent", description: "test")
        try await kit.agents.attach(agent.id, to: driver.id)
        let controller = TimelineController(driver)

        let sendTask = Task { try await controller.send("Hi") }
        while controller.isStreaming == false {
            await Task.yield()
        }
        while runtime.llm.mockClient.streamCallCount < 1 {
            await Task.yield()
        }
        sendTask.cancel()
        await driver.cancel()

        let result = await sendTask.result
        if case .failure(let error) = result {
            #expect(error is CancellationError)
        } else {
            Issue.record("Expected cancellation to fail the controller send")
        }
        #expect(controller.isStreaming == false)
    }

    @Test("a terminal persistence failure is thrown with its durability event")
    func terminalPersistenceFailurePropagatesAsControllerError() async throws {
        let persistence = MockPersistenceService()
        persistence.completeTurnFails = true
        let runtime = TestRuntime(
            workspaceRoot: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            persistence: persistence
        )
        let kit = runtime.runtime
        let driver = try await kit.timelines.create(title: "Controller")
        let agent = try await kit.agents.create(name: "Controller Agent", description: "test")
        try await kit.agents.attach(agent.id, to: driver.id)
        let controller = TimelineController(driver)

        let error = await #expect(throws: TimelineControllerError.self) {
            try await controller.send("Hi")
        }

        #expect(controller.isStreaming == false)
        if let event = error?.event, case .durabilityFailure = event {
            // Terminal persistence remains distinguishable from provider/runtime failure.
        } else {
            Issue.record("Expected the controller error to carry a durability failure event")
        }
    }

    @Test("a superseding send cancels the previous stream")
    func supersedingSendCancelsPreviousStream() async throws {
        let runtime = TestRuntime(workspaceRoot: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString))
        runtime.llm.mockClient.neverFinishingStreamCallIndices = [1]
        runtime.llm.mockClient.nextResponses = ["second reply"]
        let kit = runtime.runtime
        let driver = try await kit.timelines.create(title: "Controller")
        let agent = try await kit.agents.create(name: "Controller Agent", description: "test")
        try await kit.agents.attach(agent.id, to: driver.id)
        let controller = TimelineController(driver)

        let first = Task { try await controller.send("first") }
        // `isStreaming` flips inside `consume` *before* `driver.startTurn` reaches the LLM,
        // so it is not enough to guarantee "first" has claimed a `chatStream` call. Without the
        // second gate, a superseding "second" can be cancelled-in and reach `chatStream` first,
        // taking call index 1 — the never-finishing stream keyed to that index — and hanging on
        // the idle watchdog. Wait until "first" has actually invoked `chatStream` so the
        // never-finishing index deterministically lands on "first".
        while controller.isStreaming == false {
            await Task.yield()
        }
        while runtime.llm.mockClient.streamCallCount < 1 {
            await Task.yield()
        }

        try await controller.send("second")
        first.cancel()
        _ = await first.result

        #expect(controller.isStreaming == false)
        #expect(controller.messages.map(\.content).contains("second reply"))
    }

    @Test("a completed send records its durable outcome and turn identity")
    func completedSendRecordsDurableOutcome() async throws {
        let runtime = TestRuntime(workspaceRoot: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString))
        runtime.llm.mockClient.nextResponses = ["reply"]
        let kit = runtime.runtime
        let driver = try await kit.timelines.create(title: "Controller")
        let agent = try await kit.agents.create(name: "Controller Agent", description: "test")
        try await kit.agents.attach(agent.id, to: driver.id)
        let controller = TimelineController(driver)

        try await controller.send("Hi")

        #expect(controller.lastTurnID != nil)
        #expect(controller.lastError == nil)
        if case .completed = controller.lastOutcome {
        } else {
            Issue.record("Expected the controller to record a completed outcome")
        }
    }

    @Test("a completed send records per-round prompt-cache reports")
    func completedSendRecordsPromptCacheReports() async throws {
        let runtime = TestRuntime(workspaceRoot: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString))
        runtime.llm.mockClient.nextResponses = ["first reply", "second reply"]
        let kit = runtime.runtime
        let driver = try await kit.timelines.create(title: "Controller")
        let agent = try await kit.agents.create(name: "Controller Agent", description: "test")
        try await kit.agents.attach(agent.id, to: driver.id)
        let controller = TimelineController(driver)

        try await controller.send("Hi")

        #expect(controller.promptCacheReports.count == 1)
        #expect(controller.promptCacheReports.first?.turnID == controller.lastTurnID)
        #expect(controller.promptCacheReports.first?.modelRoundIndex == 1)

        try await controller.send("Again")

        #expect(controller.promptCacheReports.count == 1)
        #expect(controller.promptCacheReports.first?.turnID == controller.lastTurnID)
    }

    @Test("cancel() clears streaming state")
    func cancelClearsStreamingState() async throws {
        let runtime = TestRuntime(workspaceRoot: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString))
        runtime.llm.mockClient.neverFinishingStreamCallIndices = [1]
        let kit = runtime.runtime
        let driver = try await kit.timelines.create(title: "Controller")
        let agent = try await kit.agents.create(name: "Controller Agent", description: "test")
        try await kit.agents.attach(agent.id, to: driver.id)
        let controller = TimelineController(driver)

        let sendTask = Task { try await controller.send("Hi") }
        while controller.isStreaming == false {
            await Task.yield()
        }
        await controller.cancel()
        sendTask.cancel()
        _ = await sendTask.result
        for _ in 0..<20 {
            await Task.yield()
        }

        #expect(controller.isStreaming == false)
    }

    @Test("a fork binds to a controller over the direct path")
    func forkBindsToController() async throws {
        let runtime = TestRuntime(workspaceRoot: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString))
        runtime.llm.mockClient.nextResponses = ["fork reply"]
        let kit = runtime.runtime
        let driver = try await kit.timelines.create(title: "Controller")
        let agent = try await kit.agents.create(name: "Controller Agent", description: "test")
        try await kit.agents.attach(agent.id, to: driver.id)
        let fork = try await kit.timelines.fork(from: driver.timelineID)
        let controller = TimelineController(
            fork,
            context: DirectTurnContext(systemInstructions: "Audit.")
        )

        try await controller.send("Audit this.")

        #expect(controller.messages.map(\.content).contains("fork reply"))
        if case .completed = controller.lastOutcome {
        } else {
            Issue.record("Expected the fork controller to record a completed outcome")
        }
    }

    @Test("a quarantined timeline surfaces the marker and releases it")
    func quarantinedTimelineSurfacesAndReleases() async throws {
        let runtime = TestRuntime(workspaceRoot: TestRuntime.uniqueWorkspaceRoot())
        let kit = runtime.runtime
        let driver = try await kit.timelines.create(title: "Controller")
        let turnID = try await makeQuarantinedTimeline(driver: driver, persistence: runtime.persistence)
        let controller = TimelineController(driver)

        await controller.refreshQuarantine()

        #expect(controller.quarantine?.reason == "Unresolved tool intent")
        #expect(controller.quarantinedTurnID == turnID)

        try await controller.release(confirmation: QuarantineReleaseConfirmation(
            phrase: QuarantineReleaseConfirmation.requiredPhrase
        ))

        #expect(controller.quarantine == nil)
        #expect(controller.quarantinedTurnID == nil)
        #expect(try await runtime.persistence.fetchQuarantinedTurn(for: driver.id) == nil)
    }

    @Test("a send rejected by quarantine refreshes the marker instead of streaming")
    func quarantinedSendRefreshesMarker() async throws {
        let runtime = TestRuntime(workspaceRoot: TestRuntime.uniqueWorkspaceRoot())
        let kit = runtime.runtime
        let driver = try await kit.timelines.create(title: "Controller")
        let turnID = try await makeQuarantinedTimeline(driver: driver, persistence: runtime.persistence)
        // A detached Timeline takes the direct path; the managed path would reject the absent
        // Agent before reaching admission.
        let controller = TimelineController(driver, context: DirectTurnContext(systemInstructions: ""))

        let error = await #expect(throws: TimelineRuntimeRepositoryError.self) {
            try await controller.send("Hi")
        }

        #expect(error == .timelineQuarantined(timelineID: driver.id, turnID: turnID))
        #expect(controller.isStreaming == false)
        #expect(controller.quarantine?.reason == "Unresolved tool intent")
    }

    @Test("a superseded send cannot clear replacement streaming state")
    func supersededSendCannotClearReplacementStreamingState() async throws {
        let runtime = TestRuntime(workspaceRoot: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString))
        runtime.llm.mockClient.neverFinishingStreamCallIndices = [1, 2]
        runtime.llm.mockClient.nextResponses = ["replacement reply"]
        let kit = runtime.runtime
        let driver = try await kit.timelines.create(title: "Controller")
        let agent = try await kit.agents.create(name: "Controller Agent", description: "test")
        try await kit.agents.attach(agent.id, to: driver.id)
        let controller = TimelineController(driver)

        let first = Task { try await controller.send("first") }
        while controller.isStreaming == false {
            await Task.yield()
        }
        while runtime.llm.mockClient.streamCallCount < 1 {
            await Task.yield()
        }

        let second = Task { try await controller.send("second") }
        while runtime.llm.mockClient.streamCallCount < 2 {
            await Task.yield()
        }
        for _ in 0..<10 {
            await Task.yield()
        }

        #expect(controller.isStreaming)

        try await controller.send("replacement")
        second.cancel()
        first.cancel()
        _ = await second.result
        _ = await first.result
    }
}

@Suite("Timeline controller direct path")
@MainActor
struct TimelineControllerDirectPathTests {
    private func makeController(_ driver: TimelineHandle) -> TimelineController {
        TimelineController(driver, context: DirectTurnContext(systemInstructions: ""))
    }

    @Test("mirrors streamed text and completed messages")
    func mirrorsStreamedTextAndCompletedMessages() async throws {
        let runtime = TestRuntime(workspaceRoot: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString))
        runtime.llm.mockClient.nextChunks = [["Hello, ", "world!"]]
        let kit = runtime.runtime
        let driver = try await kit.timelines.create(title: "Controller")
        let controller = makeController(driver)

        try await controller.send("Hi")

        #expect(controller.isStreaming == false)
        #expect(controller.streamingText.isEmpty)
        #expect(controller.messages.map(\.content) == ["Hi", "Hello, world!"])
    }

    @Test("a direct-path controller observes and releases a quarantine")
    func directPathObservesAndReleasesQuarantine() async throws {
        let runtime = TestRuntime(workspaceRoot: TestRuntime.uniqueWorkspaceRoot())
        let kit = runtime.runtime
        let driver = try await kit.timelines.create(title: "Controller")
        let turnID = try await makeQuarantinedTimeline(driver: driver, persistence: runtime.persistence)
        let controller = makeController(driver)

        await controller.refreshQuarantine()

        #expect(controller.quarantinedTurnID == turnID)
        try await controller.release(confirmation: QuarantineReleaseConfirmation(
            phrase: QuarantineReleaseConfirmation.requiredPhrase
        ))
        #expect(controller.quarantine == nil)
    }

    @Test("a completed send clears its active task")
    func completedSendClearsActiveTask() async throws {
        let runtime = TestRuntime(workspaceRoot: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString))
        runtime.llm.mockClient.nextResponses = ["reply"]
        let kit = runtime.runtime
        let driver = try await kit.timelines.create(title: "Controller")
        var controller: TimelineController? = makeController(driver)
        weak var releasedController: TimelineController? = nil
        releasedController = controller

        try await controller!.send("Hi")
        controller = nil
        await Task.yield()

        #expect(releasedController == nil)
    }

    @Test("a provider failure is thrown with its terminal event and clears state")
    func providerFailurePropagatesAsControllerError() async throws {
        let runtime = TestRuntime(workspaceRoot: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString))
        runtime.llm.mockClient.shouldThrowError = true
        let kit = runtime.runtime
        let driver = try await kit.timelines.create(title: "Controller")
        let controller = makeController(driver)

        let error = await #expect(throws: TimelineControllerError.self) {
            try await controller.send("Hi")
        }

        #expect(controller.isStreaming == false)
        #expect(controller.streamingText.isEmpty)
        if let event = error?.event, case .error = event {
            // The provider/runtime failure remains distinguishable from cancellation.
        } else {
            Issue.record("Expected the controller error to carry a general runtime error event")
        }
    }

    @Test("cancellation is thrown as CancellationError and clears state")
    func cancellationPropagatesAsCancellationError() async throws {
        let runtime = TestRuntime(workspaceRoot: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString))
        runtime.llm.mockClient.neverFinishingStreamCallIndices = [1]
        let kit = runtime.runtime
        let driver = try await kit.timelines.create(title: "Controller")
        let controller = makeController(driver)

        let sendTask = Task { try await controller.send("Hi") }
        while controller.isStreaming == false {
            await Task.yield()
        }
        while runtime.llm.mockClient.streamCallCount < 1 {
            await Task.yield()
        }
        sendTask.cancel()
        await driver.cancel()

        let result = await sendTask.result
        if case .failure(let error) = result {
            #expect(error is CancellationError)
        } else {
            Issue.record("Expected cancellation to fail the controller send")
        }
        #expect(controller.isStreaming == false)
    }

    @Test("a terminal persistence failure is thrown with its durability event")
    func terminalPersistenceFailurePropagatesAsControllerError() async throws {
        let persistence = MockPersistenceService()
        persistence.completeTurnFails = true
        let runtime = TestRuntime(
            workspaceRoot: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            persistence: persistence
        )
        let kit = runtime.runtime
        let driver = try await kit.timelines.create(title: "Controller")
        let controller = makeController(driver)

        let error = await #expect(throws: TimelineControllerError.self) {
            try await controller.send("Hi")
        }

        #expect(controller.isStreaming == false)
        if let event = error?.event, case .durabilityFailure = event {
            // Terminal persistence remains distinguishable from provider/runtime failure.
        } else {
            Issue.record("Expected the controller error to carry a durability failure event")
        }
    }

    @Test("a superseding send cancels the previous stream")
    func supersedingSendCancelsPreviousStream() async throws {
        let runtime = TestRuntime(workspaceRoot: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString))
        runtime.llm.mockClient.neverFinishingStreamCallIndices = [1]
        runtime.llm.mockClient.nextResponses = ["second reply"]
        let kit = runtime.runtime
        let driver = try await kit.timelines.create(title: "Controller")
        let controller = makeController(driver)

        let first = Task { try await controller.send("first") }
        while controller.isStreaming == false {
            await Task.yield()
        }
        while runtime.llm.mockClient.streamCallCount < 1 {
            await Task.yield()
        }

        try await controller.send("second")
        first.cancel()
        _ = await first.result

        #expect(controller.isStreaming == false)
        #expect(controller.messages.map(\.content).contains("second reply"))
    }

    @Test("a superseded send cannot clear replacement streaming state")
    func supersededSendCannotClearReplacementStreamingState() async throws {
        let runtime = TestRuntime(workspaceRoot: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString))
        runtime.llm.mockClient.neverFinishingStreamCallIndices = [1, 2]
        runtime.llm.mockClient.nextResponses = ["replacement reply"]
        let kit = runtime.runtime
        let driver = try await kit.timelines.create(title: "Controller")
        let controller = makeController(driver)

        let first = Task { try await controller.send("first") }
        while controller.isStreaming == false {
            await Task.yield()
        }
        while runtime.llm.mockClient.streamCallCount < 1 {
            await Task.yield()
        }

        let second = Task { try await controller.send("second") }
        while runtime.llm.mockClient.streamCallCount < 2 {
            await Task.yield()
        }
        for _ in 0..<10 {
            await Task.yield()
        }

        #expect(controller.isStreaming)

        try await controller.send("replacement")
        second.cancel()
        first.cancel()
        _ = await second.result
        _ = await first.result
    }
}

/// Admits an orphan Turn on `driver`'s Timeline and interrupts it into quarantine, returning the
/// quarantined Turn's ID.
private func makeQuarantinedTimeline(
    driver: TimelineHandle,
    persistence: MockPersistenceService
) async throws -> UUID {
    let admission = try await persistence.admitTurn(
        timelineID: driver.id,
        requestID: UUID(),
        callerIntentFingerprint: "quarantine"
    )
    let turnID = admission.turn.identity.turnID
    _ = try await persistence.interruptTurn(
        turnID: turnID,
        reason: "A mutating tool intent was never resolved.",
        disposition: .quarantined("Unresolved tool intent"),
        now: Date()
    )
    return turnID
}
