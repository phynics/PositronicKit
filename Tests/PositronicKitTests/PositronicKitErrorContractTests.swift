import Foundation
import ErrorKit
@testable import PKShared
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

    // MARK: - AgentInstanceError

    @Suite("AgentInstanceError")
    struct AgentInstanceErrorTests {
        @Test("Every case maps to a unique non-zero error code in the agent domain")
        func uniqueErrorCodes() {
            let cases: [AgentInstanceError] = [
                .instanceNotFound(UUID()),
                .timelineNotFound(UUID()),
                .differentAgentAlreadyAttached(UUID()),
                .hasAttachedTimelines(count: 3),
                .nameTooShort("ab"),
                .descriptionEmpty,
                .cannotAttachToPrivateTimeline(UUID()),
                .cannotDetachFromOwnPrivateTimeline(UUID()),
            ]
            let codes = cases.map(\.errorCode)
            #expect(Set(codes).count == codes.count)
            #expect(codes.allSatisfy { $0 != 0 })
            #expect(cases.allSatisfy { $0.errorDomain == PKErrorDomain.agent })
        }

        @Test("errorDescription provides a technical description with the offending value")
        func errorDescriptionFormat() {
            let error = AgentInstanceError.nameTooShort("ab")
            #expect(error.errorDescription?.contains("ab") == true)
            #expect(error.errorDescription?.contains("too short") == true)
        }

        @Test("userFriendlyMessage truncates UUIDs to a prefix for readability")
        func userFriendlyMessageTruncatesUUID() {
            let id = UUID()
            let error = AgentInstanceError.instanceNotFound(id)
            #expect(error.userFriendlyMessage.contains(id.uuidString.prefix(8)))
            #expect(!error.userFriendlyMessage.contains(id.uuidString))
        }

        @Test("hasAttachedTimelines surfaces the count in both descriptions")
        func hasAttachedTimelinesCount() {
            let error = AgentInstanceError.hasAttachedTimelines(count: 5)
            #expect(error.errorDescription?.contains("5 timeline(s)") == true)
            #expect(error.userFriendlyMessage.contains("5 timeline(s)"))
        }

        @Test("nameTooShort includes the offending name in the technical description")
        func nameTooShortIncludesName() {
            let error = AgentInstanceError.nameTooShort("x")
            #expect(error.errorDescription?.contains("'x'") == true)
        }

        @Test("remediation defaults to nil (no recovery guidance)")
        func remediationIsNil() {
            #expect(AgentInstanceError.descriptionEmpty.remediation == nil)
            #expect(AgentInstanceError.instanceNotFound(UUID()).remediation == nil)
        }

        @Test("isBlocked defaults to false (not a permission gate)")
        func isBlockedIsFalse() {
            #expect(AgentInstanceError.instanceNotFound(UUID()).isBlocked == false)
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
            #expect(cases.allSatisfy { $0.errorDomain == PKErrorDomain.chat })
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

    // MARK: - TurnBriefingBuilderError

    @Suite("TurnBriefingBuilderError")
    struct TurnBriefingBuilderErrorTests {
        @Test("Every case maps to a unique non-zero error code in the context domain")
        func uniqueErrorCodes() {
            let embedding = TurnBriefingBuilderError.embeddingFailed(NSError(domain: "x", code: 1))
            let persistence = TurnBriefingBuilderError.persistenceFailed(NSError(domain: "x", code: 2))
            let codes = [embedding.errorCode, persistence.errorCode]
            #expect(Set(codes).count == 2)
            #expect(codes == [2001, 2002])
            #expect(embedding.errorDomain == PKErrorDomain.context)
            #expect(persistence.errorDomain == PKErrorDomain.context)
        }

        @Test("embeddingFailed produces a user-facing retrieval message")
        func embeddingFailedMessage() {
            let error = TurnBriefingBuilderError.embeddingFailed(NSError(domain: "x", code: 1))
            #expect(error.userFriendlyMessage.contains("analyze"))
            #expect(error.userFriendlyMessage.contains("context"))
        }

        @Test("persistenceFailed produces a user-facing retrieval message")
        func persistenceFailedMessage() {
            let error = TurnBriefingBuilderError.persistenceFailed(NSError(domain: "x", code: 2))
            #expect(error.userFriendlyMessage.contains("retrieve"))
            #expect(error.userFriendlyMessage.contains("memories") || error.userFriendlyMessage.contains("notes"))
        }
    }

    // MARK: - EmbeddingError

    @Suite("EmbeddingError")
    struct EmbeddingErrorTests {
        @Test("Every case maps to a unique non-zero error code in the embedding domain")
        func uniqueErrorCodes() {
            let cases: [EmbeddingError] = [
                .modelUnavailable,
                .generationFailed,
                .modelDirectoryMissing,
                .modelFilesMissing,
                .modelChecksumMismatch,
                .nativeInitializationFailed,
                .batchTextCountLimitExceeded(max: 64, actual: 100),
                .perTextByteLimitExceeded(max: 100, actual: 200),
                .totalBatchByteLimitExceeded(max: 1000, actual: 2000),
            ]
            let codes = cases.map(\.errorCode)
            #expect(Set(codes).count == codes.count)
            #expect(codes == [8001, 8002, 8003, 8004, 8005, 8006, 8007, 8008, 8009])
            #expect(cases.allSatisfy { $0.errorDomain == PKErrorDomain.embedding })
        }

        @Test("batchTextCountLimitExceeded includes both max and actual in the message")
        func batchCountMessage() {
            let error = EmbeddingError.batchTextCountLimitExceeded(max: 64, actual: 100)
            #expect(error.userFriendlyMessage.contains("64"))
            #expect(error.userFriendlyMessage.contains("100"))
            #expect(error.userFriendlyMessage.contains("batch text-count"))
        }

        @Test("perTextByteLimitExceeded includes both max and actual in the message")
        func perTextByteMessage() {
            let error = EmbeddingError.perTextByteLimitExceeded(max: 100, actual: 200)
            #expect(error.userFriendlyMessage.contains("100"))
            #expect(error.userFriendlyMessage.contains("200"))
            #expect(error.userFriendlyMessage.contains("per-text byte"))
        }

        @Test("totalBatchByteLimitExceeded includes both max and actual in the message")
        func totalBatchByteMessage() {
            let error = EmbeddingError.totalBatchByteLimitExceeded(max: 1000, actual: 2000)
            #expect(error.userFriendlyMessage.contains("1000"))
            #expect(error.userFriendlyMessage.contains("2000"))
            #expect(error.userFriendlyMessage.contains("total batch byte"))
        }

        @Test("modelUnavailable message references device availability")
        func modelUnavailableMessage() {
            #expect(EmbeddingError.modelUnavailable.userFriendlyMessage.contains("not available"))
        }

        @Test("Equatable conformance compares associated values")
        func equatable() {
            #expect(EmbeddingError.modelUnavailable == .modelUnavailable)
            #expect(
                EmbeddingError.batchTextCountLimitExceeded(max: 1, actual: 2)
                == .batchTextCountLimitExceeded(max: 1, actual: 2)
            )
            #expect(
                EmbeddingError.batchTextCountLimitExceeded(max: 1, actual: 2)
                != .batchTextCountLimitExceeded(max: 1, actual: 3)
            )
        }
    }
}
