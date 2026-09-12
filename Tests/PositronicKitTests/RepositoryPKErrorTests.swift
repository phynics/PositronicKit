import Foundation
import PKContracts
@testable import PositronicKit
import Testing

/// Verifies stable identity and user-facing presentation for repository errors.
@Suite("Repository PKError contracts")
struct RepositoryPKErrorTests {
    private struct ThreadErrorCase {
        let error: ThreadRuntimeRepositoryError
        let code: Int
    }

    private struct WorkspaceErrorCase {
        let error: WorkspaceBindingRepositoryError
        let code: Int
    }

    @Test("Thread repository errors expose unique stable identities")
    func threadRepositoryErrorsHaveStableIdentities() {
        let threadID = UUID()
        let turnID = UUID()
        let requestID = UUID()
        let toolCallID = "tool-call"
        let messageID = UUID()
        let expectedThreadID = UUID()
        let actualThreadID = UUID()
        let cases = [
            ThreadErrorCase(error: .threadNotFound(threadID), code: 6101),
            ThreadErrorCase(error: .turnNotFound(turnID), code: 6102),
            ThreadErrorCase(error: .threadBusy(threadID: threadID, activeTurnID: turnID), code: 6103),
            ThreadErrorCase(error: .idempotencyConflict(requestID: requestID), code: 6104),
            ThreadErrorCase(error: .recoveryRequired(threadID: threadID, turnID: turnID), code: 6105),
            ThreadErrorCase(error: .invalidTransition(turnID: turnID, lifecycle: .running), code: 6106),
            ThreadErrorCase(error: .toolIntentRequired(turnID: turnID, toolCallID: toolCallID), code: 6107),
            ThreadErrorCase(error: .duplicateToolIntent(turnID: turnID, toolCallID: toolCallID), code: 6108),
            ThreadErrorCase(error: .duplicateToolResult(turnID: turnID, toolCallID: toolCallID), code: 6109),
            ThreadErrorCase(error: .appendOnlyViolation(messageID: messageID), code: 6110),
            ThreadErrorCase(error: .historyDeletionForbidden(threadID: threadID), code: 6111),
            ThreadErrorCase(error: .summarySourceMissing(messageID: messageID), code: 6112),
            ThreadErrorCase(error: .confirmationRequired, code: 6113),
            ThreadErrorCase(error: .runtimeRepositoryRequired(threadID: threadID), code: 6114),
            ThreadErrorCase(error: .authorityCoordinatorRequired(threadID: threadID), code: 6115),
            ThreadErrorCase(
                error: .inputMessageThreadMismatch(
                    messageID: messageID,
                    expectedThreadID: expectedThreadID,
                    actualThreadID: actualThreadID
                ),
                code: 6116
            ),
            ThreadErrorCase(
                error: .finalMessageThreadMismatch(
                    messageID: messageID,
                    expectedThreadID: expectedThreadID,
                    actualThreadID: actualThreadID
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
                domain: PKErrorDomain.thread,
                code: testCase.code,
                description: testCase.error.description
            )
        }
    }

    @Test("Workspace binding repository errors expose unique stable identities")
    func workspaceBindingRepositoryErrorsHaveStableIdentities() {
        let workspaceID = UUID()
        let threadID = UUID()
        let cases = [
            WorkspaceErrorCase(
                error: .workspaceAlreadyBound(workspaceID: workspaceID, threadID: threadID),
                code: 3101
            ),
            WorkspaceErrorCase(
                error: .bindingNotFound(workspaceID: workspaceID, threadID: threadID),
                code: 3102
            ),
            WorkspaceErrorCase(
                error: .transferSourceMismatch(workspaceID: workspaceID, threadID: threadID),
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
