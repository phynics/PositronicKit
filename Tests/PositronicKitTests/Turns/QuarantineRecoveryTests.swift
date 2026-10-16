import Foundation
import PKTestSupport
@testable import PositronicKit
import Testing

@Suite("Quarantine recovery", .tags(.integration))
struct QuarantineRecoveryTests {
    @Test("a quarantined Turn blocks admission until the facade releases it")
    func releaseUnblocksAdmission() async throws {
        let runtime = TestRuntime(workspaceRoot: TestRuntime.uniqueWorkspaceRoot())
        runtime.llm.mockClient.nextResponses = ["reply"]
        let kit = runtime.runtime
        let timeline = try await kit.timelines.create(title: "Quarantine")
        let turnID = try await quarantineTimeline(timelineID: timeline.id, persistence: runtime.persistence)

        let quarantined = try await kit.timelines.quarantinedTurn(for: timeline.id)
        #expect(quarantined?.identity.turnID == turnID)
        #expect(quarantined?.isQuarantined == true)

        let blocked = await #expect(throws: TimelineRuntimeRepositoryError.self) {
            _ = try await timeline.startDirectTurn(
                "blocked",
                context: DirectTurnContext(systemInstructions: "")
            )
        }
        #expect(blocked == .timelineQuarantined(timelineID: timeline.id, turnID: turnID))

        let wrongPhrase = await #expect(throws: TimelineRuntimeRepositoryError.self) {
            _ = try await kit.timelines.releaseQuarantine(
                turnID: turnID,
                confirmation: QuarantineReleaseConfirmation(phrase: "yes")
            )
        }
        #expect(wrongPhrase == .confirmationRequired)

        let released = try await kit.timelines.releaseQuarantine(
            turnID: turnID,
            confirmation: QuarantineReleaseConfirmation(
                phrase: QuarantineReleaseConfirmation.requiredPhrase
            )
        )
        #expect(released.isQuarantined == false)
        #expect(try await kit.timelines.quarantinedTurn(for: timeline.id) == nil)

        let admitted = try await timeline.startDirectTurn(
            "unblocked",
            context: DirectTurnContext(systemInstructions: "")
        )
        #expect(admitted.id != turnID)
        #expect(try await admitted.outcome() == .completed)
    }

    @Test("releaseQuarantine reports a missing Turn")
    func releaseReportsMissingTurn() async throws {
        let runtime = TestRuntime(workspaceRoot: TestRuntime.uniqueWorkspaceRoot())
        let kit = runtime.runtime
        _ = try await kit.timelines.create(title: "Clear")
        let missing = UUID()

        let error = await #expect(throws: TimelineRuntimeRepositoryError.self) {
            _ = try await kit.timelines.releaseQuarantine(
                turnID: missing,
                confirmation: QuarantineReleaseConfirmation(
                    phrase: QuarantineReleaseConfirmation.requiredPhrase
                )
            )
        }
        #expect(error == .turnNotFound(missing))
    }

    @Test("the handle exposes the same quarantine view as the facade")
    func handleMatchesFacade() async throws {
        let runtime = TestRuntime(workspaceRoot: TestRuntime.uniqueWorkspaceRoot())
        let kit = runtime.runtime
        let timeline = try await kit.timelines.create(title: "Handle")
        let turnID = try await quarantineTimeline(timelineID: timeline.id, persistence: runtime.persistence)

        #expect(try await timeline.quarantinedTurn()?.identity.turnID == turnID)
        _ = try await timeline.releaseQuarantine(
            turnID: turnID,
            confirmation: QuarantineReleaseConfirmation(
                phrase: QuarantineReleaseConfirmation.requiredPhrase
            )
        )
        #expect(try await timeline.quarantinedTurn() == nil)
    }
}

/// Admits an orphan Turn on `timelineID` and interrupts it into quarantine, returning the
/// quarantined Turn's ID.
private func quarantineTimeline(
    timelineID: UUID,
    persistence: MockPersistenceService
) async throws -> UUID {
    let admission = try await persistence.admitTurn(
        timelineID: timelineID,
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
