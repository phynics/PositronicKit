import Foundation
import PKContracts
@testable import PositronicKit
import Testing

/// Verifies stable identity and user-facing presentation for repository errors.
@Suite("Repository PKError contracts", .tags(.unit))
struct RepositoryPKErrorTests {
    private struct TimelineErrorCase {
        let error: TimelineRuntimeRepositoryError
        let code: Int
    }

    private struct WorkspaceErrorCase {
        let error: WorkspaceBindingRepositoryError
        let code: Int
    }

    @Test("Timeline repository errors expose unique stable identities")
    func timelineRepositoryErrorsHaveStableIdentities() {
        let timelineID = UUID()
        let turnID = UUID()
        let requestID = UUID()
        let toolCallID = "tool-call"
        let messageID = UUID()
        let expectedTimelineID = UUID()
        let actualTimelineID = UUID()
        let cases = [
            TimelineErrorCase(error: .timelineNotFound(timelineID), code: 6101),
            TimelineErrorCase(error: .turnNotFound(turnID), code: 6102),
            TimelineErrorCase(error: .timelineBusy(timelineID: timelineID, activeTurnID: turnID), code: 6103),
            TimelineErrorCase(error: .idempotencyConflict(requestID: requestID), code: 6104),
            TimelineErrorCase(error: .timelineQuarantined(timelineID: timelineID, turnID: turnID), code: 6105),
            TimelineErrorCase(error: .invalidTransition(turnID: turnID, lifecycle: .running), code: 6106),
            TimelineErrorCase(error: .toolIntentRequired(turnID: turnID, toolCallID: toolCallID), code: 6107),
            TimelineErrorCase(error: .duplicateToolIntent(turnID: turnID, toolCallID: toolCallID), code: 6108),
            TimelineErrorCase(error: .duplicateToolResult(turnID: turnID, toolCallID: toolCallID), code: 6109),
            TimelineErrorCase(error: .appendOnlyViolation(messageID: messageID), code: 6110),
            TimelineErrorCase(error: .historyDeletionForbidden(timelineID: timelineID), code: 6111),
            TimelineErrorCase(error: .summarySourceMissing(messageID: messageID), code: 6112),
            TimelineErrorCase(error: .confirmationRequired, code: 6113),
            TimelineErrorCase(error: .runtimeRepositoryRequired(timelineID: timelineID), code: 6114),
            TimelineErrorCase(error: .authorityCoordinatorRequired(timelineID: timelineID), code: 6115),
            TimelineErrorCase(
                error: .inputMessageTimelineMismatch(
                    messageID: messageID,
                    expectedTimelineID: expectedTimelineID,
                    actualTimelineID: actualTimelineID
                ),
                code: 6116
            ),
            TimelineErrorCase(
                error: .finalMessageTimelineMismatch(
                    messageID: messageID,
                    expectedTimelineID: expectedTimelineID,
                    actualTimelineID: actualTimelineID
                ),
                code: 6117
            ),
        ]

        #expect(cases.count == 17)
        #expect(cases.map(\.code) == Array(6101...6117))
        #expect(Set(cases.map(\.code)).count == cases.count)
        #expect(Set(cases.map(\.code)).isDisjoint(with: Set(6001...6005)))

        for testCase in cases {
            assertPKError(
                testCase.error,
                domain: PKErrorDomain.timeline,
                code: testCase.code,
                description: testCase.error.description
            )
        }
    }

    @Test("Workspace binding repository errors expose unique stable identities")
    func workspaceBindingRepositoryErrorsHaveStableIdentities() {
        let workspaceID = UUID()
        let timelineID = UUID()
        let cases = [
            WorkspaceErrorCase(
                error: .workspaceAlreadyBound(workspaceID: workspaceID, timelineID: timelineID),
                code: 3101
            ),
            WorkspaceErrorCase(
                error: .bindingNotFound(workspaceID: workspaceID, timelineID: timelineID),
                code: 3102
            ),
            WorkspaceErrorCase(
                error: .transferSourceMismatch(workspaceID: workspaceID, timelineID: timelineID),
                code: 3103
            ),
        ]

        #expect(cases.map(\.code) == Array(3101...3103))
        #expect(Set(cases.map(\.code)).count == cases.count)
        #expect(Set(cases.map(\.code)).isDisjoint(with: Set(3001...3005)))

        for testCase in cases {
            assertPKError(
                testCase.error,
                domain: PKErrorDomain.workspace,
                code: testCase.code,
                description: testCase.error.description
            )
        }
    }

    private func assertPKError(
        _ error: any PKError,
        domain: String,
        code: Int,
        description: String
    ) {
        #expect(error.errorDomain == domain)
        #expect(error.errorCode == code)
        #expect(!error.userFriendlyMessage.isEmpty)
        #expect(error.userFriendlyMessage == description)
        #expect(!error.localizedDescription.isEmpty)
        #expect(error.localizedDescription.contains(description))
        #expect(error.isBlocked == false)

        let identity = TurnEvent.ErrorIdentity.extracting(from: error)
        #expect(identity?.domain == domain)
        #expect(identity?.code == code)
        #expect(identity?.isBlocked == false)
    }
}
