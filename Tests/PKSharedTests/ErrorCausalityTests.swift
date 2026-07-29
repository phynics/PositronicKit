import Testing
import Foundation
@testable import PKShared
import PKUtilities
import ErrorKit

/// Regression tests for PKRR-014: pipeline wrapping must not destroy the
/// underlying error's structured identity. `ErrorIdentity.extracting` traverses
/// `CausalError` wrappers (e.g. `PipelineError`) to find the root `PKError`
/// identity, preserving the original domain/code/isBlocked instead of collapsing
/// to the generic pipeline code 4001.
@Suite struct ErrorCausalityTests {

    // MARK: - Provider HTTP errors retain identity through pipeline wrapping

    @Test("Provider 429 retains LLM/HTTP identity through PipelineError.stageFailed")
    func provider429RetainsIdentityThroughStageFailed() {
        let providerError = LLMServiceError.httpError(
            provider: "OpenAI",
            statusCode: 429,
            responseBody: "rate limited",
            retryAfter: 30
        )
        let wrapped = PipelineError.stageFailed(id: "LLMStreamingStage", underlyingError: providerError)

        let identity = ChatEvent.ErrorIdentity.extracting(from: wrapped)

        #expect(identity?.domain == PKErrorDomain.llm)
        #expect(identity?.code == 1004)
        #expect(identity?.isBlocked == false)
    }

    @Test("Provider 429 retains LLM/HTTP identity through PipelineError.cleanupFailed")
    func provider429RetainsIdentityThroughCleanupFailed() {
        let providerError = LLMServiceError.httpError(
            provider: "OpenRouter",
            statusCode: 429,
            responseBody: "slow down",
            retryAfter: nil
        )
        let wrapped = PipelineError.cleanupFailed(id: "PersistenceStage", underlyingError: providerError)

        let identity = ChatEvent.ErrorIdentity.extracting(from: wrapped)

        #expect(identity?.domain == PKErrorDomain.llm)
        #expect(identity?.code == 1004)
    }

    @Test("Provider network error retains identity through pipeline wrapping")
    func providerNetworkErrorRetainsIdentity() {
        let providerError = LLMServiceError.networkError("connection reset")
        let wrapped = PipelineError.stageFailed(id: "LLMStreamingStage", underlyingError: providerError)

        let identity = ChatEvent.ErrorIdentity.extracting(from: wrapped)

        #expect(identity?.domain == PKErrorDomain.llm)
        #expect(identity?.code == 1003)
    }

    // MARK: - Blocked tool errors remain classifiable after wrapping

    @Test("Blocked tool error retains identity and isBlocked through pipeline wrapping")
    func blockedToolErrorRetainsIdentity() {
        let toolError = ToolError.permissionDenied("rm")
        let wrapped = PipelineError.stageFailed(id: "ToolExecutionStage", underlyingError: toolError)

        let identity = ChatEvent.ErrorIdentity.extracting(from: wrapped)

        #expect(identity?.domain == PKErrorDomain.tool)
        #expect(identity?.code == 210)
        #expect(identity?.isBlocked == true)
    }

    @Test("Attached tools disallowed retains isBlocked through pipeline wrapping")
    func attachedToolsDisallowedRetainsBlocked() {
        let toolError = ToolError.attachedToolsDisallowedOnPrivateTimeline
        let wrapped = PipelineError.stageFailed(id: "ToolRouterStage", underlyingError: toolError)

        let identity = ChatEvent.ErrorIdentity.extracting(from: wrapped)

        #expect(identity?.domain == PKErrorDomain.tool)
        #expect(identity?.code == 207)
        #expect(identity?.isBlocked == true)
    }

    @Test("PathError.accessDenied retains isBlocked through pipeline wrapping")
    func pathErrorAccessDeniedRetainsBlocked() {
        let pathError = PathSanitizer.PathError.accessDenied("/etc/passwd")
        let wrapped = PipelineError.stageFailed(id: "FileReadStage", underlyingError: pathError)

        let identity = ChatEvent.ErrorIdentity.extracting(from: wrapped)

        #expect(identity?.domain == PKErrorDomain.filesystem)
        #expect(identity?.code == 101)
        #expect(identity?.isBlocked == true)
    }

    // MARK: - Cancellation does not collapse to pipeline code 4001

    @Test("CancellationError wrapped in PipelineError does not yield pipeline identity")
    func cancellationDoesNotCollapseToPipelineCode() {
        let wrapped = PipelineError.stageFailed(id: "LLMStreamingStage", underlyingError: CancellationError())

        let identity = ChatEvent.ErrorIdentity.extracting(from: wrapped)

        #expect(identity == nil, "CancellationError should not yield pipeline code 4001; got \(String(describing: identity))")
    }

    @Test("CancellationError wrapped in cleanupFailed does not yield pipeline identity")
    func cancellationInCleanupDoesNotCollapse() {
        let wrapped = PipelineError.cleanupFailed(id: "CleanupStage", underlyingError: CancellationError())

        let identity = ChatEvent.ErrorIdentity.extracting(from: wrapped)

        #expect(identity == nil)
    }

    @Test("Bare CancellationError yields nil identity")
    func bareCancellationYieldsNil() {
        let identity = ChatEvent.ErrorIdentity.extracting(from: CancellationError())
        #expect(identity == nil)
    }

    // MARK: - Non-PKError wrapped errors do not collapse to pipeline code

    @Test("Non-PKError wrapped in PipelineError yields nil, not pipeline 4001")
    func nonPKErrorWrappedYieldsNil() {
        struct ForeignError: Error, LocalizedError {
            var errorDescription: String? { "foreign failure" }
        }
        let wrapped = PipelineError.stageFailed(id: "SomeStage", underlyingError: ForeignError())

        let identity = ChatEvent.ErrorIdentity.extracting(from: wrapped)

        #expect(identity == nil, "Non-PKError should not yield pipeline code 4001; got \(String(describing: identity))")
    }

    // MARK: - Compound failures retain primary root cause identity

    @Test("Compound failure retains primary's root cause identity")
    func compoundFailureRetainsPrimaryRootCause() {
        let providerError = LLMServiceError.httpError(
            provider: "OpenAI",
            statusCode: 429,
            responseBody: "rate limited",
            retryAfter: nil
        )
        let primary = PipelineError.stageFailed(id: "LLMStreamingStage", underlyingError: providerError)
        let cleanupFailures: [Error] = [URLError(.notConnectedToInternet)]
        let compound = PipelineError.compoundFailure(primary: primary, cleanupFailures: cleanupFailures)

        let identity = ChatEvent.ErrorIdentity.extracting(from: compound)

        #expect(identity?.domain == PKErrorDomain.llm)
        #expect(identity?.code == 1004)
    }

    @Test("Compound failure with blocked primary retains isBlocked")
    func compoundFailureWithBlockedPrimaryRetainsBlocked() {
        let toolError = ToolError.permissionDenied("dd")
        let primary = PipelineError.stageFailed(id: "ToolExecutionStage", underlyingError: toolError)
        let compound = PipelineError.compoundFailure(primary: primary, cleanupFailures: [URLError(.badURL)])

        let identity = ChatEvent.ErrorIdentity.extracting(from: compound)

        #expect(identity?.domain == PKErrorDomain.tool)
        #expect(identity?.code == 210)
        #expect(identity?.isBlocked == true)
    }

    @Test("Compound failure with non-PKError primary yields nil")
    func compoundFailureWithNonPKErrorPrimaryYieldsNil() {
        let primary = PipelineError.stageFailed(id: "SomeStage", underlyingError: CancellationError())
        let compound = PipelineError.compoundFailure(primary: primary, cleanupFailures: [])

        let identity = ChatEvent.ErrorIdentity.extracting(from: compound)

        #expect(identity == nil)
    }

    // MARK: - ChatEvent.error factory preserves root cause identity

    @Test("ChatEvent.error factory preserves provider identity through pipeline wrapping")
    func chatEventErrorFactoryPreservesProviderIdentity() {
        let providerError = LLMServiceError.httpError(
            provider: "OpenAI",
            statusCode: 429,
            responseBody: "rate limited",
            retryAfter: nil
        )
        let wrapped = PipelineError.stageFailed(id: "LLMStreamingStage", underlyingError: providerError)
        let event = ChatEvent.error(wrapped)

        if case let .error(.error(message: _, identity: identity)) = event {
            #expect(identity?.domain == PKErrorDomain.llm)
            #expect(identity?.code == 1004)
        } else {
            Issue.record("Expected .error event, got \(event)")
        }
    }

    @Test("ChatEvent.error factory preserves blocked identity through pipeline wrapping")
    func chatEventErrorFactoryPreservesBlockedIdentity() {
        let toolError = ToolError.permissionDenied("rm")
        let wrapped = PipelineError.stageFailed(id: "ToolExecutionStage", underlyingError: toolError)
        let event = ChatEvent.error(wrapped)

        if case let .error(.error(message: _, identity: identity)) = event {
            #expect(identity?.domain == PKErrorDomain.tool)
            #expect(identity?.code == 210)
            #expect(identity?.isBlocked == true)
        } else {
            Issue.record("Expected .error event, got \(event)")
        }
    }

    // MARK: - Direct (non-wrapped) errors still work correctly

    @Test("Direct PKError retains identity without wrapping")
    func directPKErrorRetainsIdentity() {
        let error = LLMServiceError.httpError(
            provider: "OpenAI", statusCode: 500, responseBody: "server error", retryAfter: nil
        )
        let identity = ChatEvent.ErrorIdentity.extracting(from: error)
        #expect(identity?.domain == PKErrorDomain.llm)
        #expect(identity?.code == 1004)
    }

    @Test("Direct non-PKError yields nil")
    func directNonPKErrorYieldsNil() {
        struct PlainError: Error {}
        let identity = ChatEvent.ErrorIdentity.extracting(from: PlainError())
        #expect(identity == nil)
    }

    // MARK: - PipelineError's own identity is not surfaced as fallback

    @Test("PipelineError.stageFailed identity is not used as fallback for non-PKError cause")
    func pipelineErrorIdentityNotUsedAsFallback() {
        let wrapped = PipelineError.stageFailed(id: "Stage", underlyingError: URLError(.timedOut))

        let identity = ChatEvent.ErrorIdentity.extracting(from: wrapped)

        #expect(identity == nil, "URLError wrapped in PipelineError should yield nil, not pipeline 4001")
    }

    @Test("PipelineError.compoundFailure identity is not used as fallback for non-PKError causes")
    func compoundFailureIdentityNotUsedAsFallback() {
        let compound = PipelineError.compoundFailure(
            primary: CancellationError(),
            cleanupFailures: [URLError(.badURL)]
        )

        let identity = ChatEvent.ErrorIdentity.extracting(from: compound)

        #expect(identity == nil)
    }
}
