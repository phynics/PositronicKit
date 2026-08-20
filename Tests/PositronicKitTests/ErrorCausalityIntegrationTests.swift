import Foundation
import Testing
@testable import PKContracts
import PKUtilities
@testable import PositronicKit

/// Integration tests for PKRR-014: `LLMStreamError` (a purpose-built `CausalError`
/// wrapper) retains its own `PKError` identity (llm/1005) when its underlying cause
/// is a foreign non-`PKError` error, and that identity survives pipeline wrapping.
@Suite struct ErrorCausalityIntegrationTests {

    @Test("LLMStreamError retains llm/1005 identity for foreign URLError cause")
    func llmStreamErrorRetainsIdentityForForeignCause() {
        let foreign = URLError(.timedOut)
        let streamError = LLMStreamError.providerStreamFailed(underlying: foreign)

        let identity = TurnEvent.ErrorIdentity.extracting(from: streamError)

        #expect(identity?.domain == PKErrorDomain.llm)
        #expect(identity?.code == 1005)
        #expect(identity?.isBlocked == false)
    }

    @Test("LLMStreamError wrapped in PipelineError retains llm/1005 identity")
    func llmStreamErrorRetainsIdentityThroughPipelineWrapping() {
        let foreign = URLError(.notConnectedToInternet)
        let streamError = LLMStreamError.providerStreamFailed(underlying: foreign)
        let wrapped = PipelineError.stageFailed(id: "LLMStreamingStage", underlyingError: streamError)

        let identity = TurnEvent.ErrorIdentity.extracting(from: wrapped)

        #expect(identity?.domain == PKErrorDomain.llm)
        #expect(identity?.code == 1005)
    }

    @Test("LLMStreamError in compound failure retains llm/1005 identity")
    func llmStreamErrorInCompoundFailureRetainsIdentity() {
        let foreign = URLError(.badURL)
        let streamError = LLMStreamError.providerStreamFailed(underlying: foreign)
        let primary = PipelineError.stageFailed(id: "LLMStreamingStage", underlyingError: streamError)
        let compound = PipelineError.compoundFailure(
            primary: primary,
            cleanupFailures: [URLError(.cannotConnectToHost)]
        )

        let identity = TurnEvent.ErrorIdentity.extracting(from: compound)

        #expect(identity?.domain == PKErrorDomain.llm)
        #expect(identity?.code == 1005)
    }

    @Test("WorkspaceError.accessDenied retains blocked identity through pipeline wrapping")
    func workspaceErrorRetainsBlockedThroughPipelineWrapping() {
        let wsError = WorkspaceError.accessDenied
        let wrapped = PipelineError.stageFailed(id: "WorkspaceStage", underlyingError: wsError)

        let identity = TurnEvent.ErrorIdentity.extracting(from: wrapped)

        #expect(identity?.domain == PKErrorDomain.workspace)
        #expect(identity?.code == 3002)
        #expect(identity?.isBlocked == true)
    }
}
