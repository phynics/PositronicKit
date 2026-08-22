import Foundation
import ErrorKit
@testable import PKContracts
import PKUtilities
@testable import PositronicKit
import Testing

/// Coverage for the package's `PKError`-conforming error enums.
///
/// These enums define stable `errorDomain`/`errorCode` pairs and `userFriendlyMessage`
/// strings that downstream consumers (Monad, Yakamoz) rely on for classification and display.
/// They previously had zero direct coverage — the domain/code/message contracts were only
/// exercised incidentally through higher-level integration paths, leaving regressions in
/// error identity undetectable.
@Suite("PositronicKit error contracts")
struct PositronicKitErrorContractTests {
    // MARK: - TurnError

    @Suite("TurnError")
    struct TurnErrorTests {
        @Test("invalidMaxModelRounds has a stable public error identity")
        func stableErrorIdentity() {
            let error = TurnError.invalidMaxModelRounds(0)

            #expect(error.errorDomain == PKErrorDomain.turn)
            #expect(error.errorCode == 9008)
        }

        @Test("invalidMaxModelRounds explains the invalid value and recovery")
        func messageAndRemediation() {
            let error = TurnError.invalidMaxModelRounds(-2)

            #expect(error.userFriendlyMessage == "maxModelRounds must be at least 1; received -2.")
            #expect(error.remediation == "Pass a maxModelRounds value greater than or equal to 1.")
        }

        @Test("invalidMaxModelRounds supports equality and checked sendability")
        func equalityAndSendability() {
            let error = TurnError.invalidMaxModelRounds(0)

            #expect(error == .invalidMaxModelRounds(0))
            #expect(error != .invalidMaxModelRounds(-1))
            requireSendable(error)
        }

        @Test("execution authority cases use stable turn identities")
        func executionAuthorityIdentities() {
            let threadID = UUID()
            let requestedAgentID = UUID()
            let cases: [TurnError] = [
                .managedExecutionRequiresAttachedAgent(threadID),
                .directExecutionRequiresDetachedThread(threadID),
                .managedExecutionAgentMismatch(
                    threadID: threadID,
                    requestedAgentID: requestedAgentID,
                    attachedAgentID: nil
                ),
            ]

            #expect(cases.map(\.errorCode) == [9021, 9022, 9023])
            #expect(cases.allSatisfy { $0.errorDomain == PKErrorDomain.turn })
            #expect(cases.allSatisfy { $0.errorDescription?.contains(threadID.uuidString) == true })
        }

        @Test("execution authority cases provide actionable remediation")
        func executionAuthorityRemediation() {
            #expect(TurnError.managedExecutionRequiresAttachedAgent(UUID()).remediation?.contains("Attach") == true)
            #expect(TurnError.directExecutionRequiresDetachedThread(UUID()).remediation?.contains("Detach") == true)
            #expect(TurnError.managedExecutionAgentMismatch(
                threadID: UUID(),
                requestedAgentID: UUID(),
                attachedAgentID: nil
            ).remediation?.contains("currently attached") == true)
        }

        private func requireSendable<T: Sendable>(_: T) {}
    }

    // MARK: - AgentError

    @Suite("AgentError")
    struct AgentErrorTests {
        @Test("Every case maps to a unique non-zero error code in the agent domain")
        func uniqueErrorCodes() {
            let cases: [AgentError] = [
                .agentNotFound(UUID()),
                .differentAgentAlreadyAttached(UUID()),
                .hasAttachedThreads(count: 3),
                .nameTooShort("ab"),
                .descriptionEmpty,
                .cannotAttachToPrivateThread(UUID()),
                .cannotDetachFromOwnPrivateThread(UUID()),
            ]
            let codes = cases.map(\.errorCode)
            #expect(Set(codes).count == codes.count)
            #expect(codes.allSatisfy { $0 != 0 })
            #expect(cases.allSatisfy { $0.errorDomain == PKErrorDomain.agent })
        }

        @Test("errorDescription provides a technical description with the offending value")
        func errorDescriptionFormat() {
            let error = AgentError.nameTooShort("ab")
            #expect(error.errorDescription?.contains("ab") == true)
            #expect(error.errorDescription?.contains("too short") == true)
        }

        @Test("userFriendlyMessage truncates UUIDs to a prefix for readability")
        func userFriendlyMessageTruncatesUUID() {
            let id = UUID()
            let error = AgentError.agentNotFound(id)
            #expect(error.userFriendlyMessage.contains(id.uuidString.prefix(8)))
            #expect(!error.userFriendlyMessage.contains(id.uuidString))
        }

        @Test("hasAttachedThreads surfaces the count in both descriptions")
        func hasAttachedThreadsCount() {
            let error = AgentError.hasAttachedThreads(count: 5)
            #expect(error.errorDescription?.contains("5 thread(s)") == true)
            #expect(error.userFriendlyMessage.contains("5 thread(s)"))
        }

        @Test("nameTooShort includes the offending name in the technical description")
        func nameTooShortIncludesName() {
            let error = AgentError.nameTooShort("x")
            #expect(error.errorDescription?.contains("'x'") == true)
        }

        @Test("remediation defaults to nil (no recovery guidance)")
        func remediationIsNil() {
            #expect(AgentError.descriptionEmpty.remediation == nil)
            #expect(AgentError.agentNotFound(UUID()).remediation == nil)
        }

        @Test("isBlocked defaults to false (not a permission gate)")
        func isBlockedIsFalse() {
            #expect(AgentError.agentNotFound(UUID()).isBlocked == false)
        }
    }

    // MARK: - AgentContextError

    @Suite("AgentContextError")
    struct AgentContextErrorTests {
        @Test("identityMismatch exposes a structured context identity")
        func stableErrorIdentity() {
            let error = AgentContextError.identityMismatch(expected: UUID(), actual: UUID())

            #expect(error.errorDomain == PKErrorDomain.context)
            #expect(error.errorCode == 2001)
            #expect(error.userFriendlyMessage.contains("different Agent"))
            #expect(error.remediation == nil)
            #expect(error.isBlocked == false)
        }
    }

    // MARK: - SidecarError

    @Suite("SidecarError")
    struct SidecarErrorTests {
        @Test("Every case maps to a unique non-zero error code in the chat domain")
        func uniqueErrorCodes() {
            let cases: [SidecarError] = [
                .duplicateDirectiveNames(["a", "b"]),
                .reservedOrInvalidName("bad"),
                .conflictsWithExplicitStructuredOutput,
            ]
            let codes = cases.map(\.errorCode)
            #expect(Set(codes).count == codes.count)
            #expect(codes == [5101, 5102, 5103])
            #expect(cases.allSatisfy { $0.errorDomain == PKErrorDomain.turn })
        }

        @Test("duplicateDirectiveNames lists the duplicates in the message")
        func duplicateNamesMessage() {
            let error = SidecarError.duplicateDirectiveNames(["alpha", "beta"])
            #expect(error.userFriendlyMessage.contains("alpha"))
            #expect(error.userFriendlyMessage.contains("beta"))
            #expect(error.userFriendlyMessage.contains("unique"))
        }

        @Test("reservedOrInvalidName includes the offending name")
        func reservedNameMessage() {
            let error = SidecarError.reservedOrInvalidName("system")
            #expect(error.userFriendlyMessage.contains("system"))
            #expect(error.userFriendlyMessage.contains("reserved"))
        }

        @Test("conflictsWithExplicitStructuredOutput explains the mutual exclusion")
        func conflictMessage() {
            let error = SidecarError.conflictsWithExplicitStructuredOutput
            #expect(error.userFriendlyMessage.contains("sidecar"))
            #expect(error.userFriendlyMessage.contains("structuredOutput"))
        }

        @Test("Equatable conformance allows comparison")
        func equatable() {
            #expect(SidecarError.conflictsWithExplicitStructuredOutput == .conflictsWithExplicitStructuredOutput)
            #expect(SidecarError.duplicateDirectiveNames(["a"]) == .duplicateDirectiveNames(["a"]))
            #expect(SidecarError.duplicateDirectiveNames(["a"]) != .duplicateDirectiveNames(["b"]))
        }
    }

}
