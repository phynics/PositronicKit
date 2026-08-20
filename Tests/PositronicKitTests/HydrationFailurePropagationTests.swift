import Foundation
import PKContracts
import PKUtilities
import PKTestSupport
@testable import PositronicKit
import Testing

/// PKRR-005: hydration failure during `run(_:)` must propagate as a typed `ThreadError`
/// before any user input is persisted. A brand-new, never-persisted thread throws
/// `ThreadError.threadNotFound`; a transient store fault throws `ThreadError.unavailable`.
/// Neither is swallowed — the turn does not proceed unhydrated.
struct HydrationFailurePropagationTests {
    @Test("run(_:) throws threadNotFound for a never-created thread ID (PKRR-005)")
    func runThrowsForMissingThread() async throws {
        let mockLLM = MockLLMService()
        let kit = PositronicKit(configuration: .init(
            provider: .init(languageModel: mockLLM),
            persistence: .inMemory()
        ))

        let unresolvedThreadId = UUID()

        await #expect(throws: ThreadError.threadNotFound) {
            _ = try await kit.run(TurnRequest(
                threadID: unresolvedThreadId,
                message: "should not reach the engine"
            ))
        }

        #expect(mockLLM.generationCaptureHistory.isEmpty)
    }

    @Test("run(_:) throws unavailable when the thread store fails (PKRR-005)")
    func runThrowsUnavailableForStoreFailure() async throws {
        let failingThreadPersistence = FailingThreadPersistence(fetchFails: true)
        let mockLLM = MockLLMService()
        let kit = PositronicKit(configuration: .init(
            provider: .init(languageModel: mockLLM),
            persistence: .init(threadPersistence: failingThreadPersistence)
        ))

        let unresolvedThreadId = UUID()

        await #expect(throws: ThreadError.unavailable) {
            _ = try await kit.run(TurnRequest(
                threadID: unresolvedThreadId,
                message: "should not reach the engine"
            ))
        }

        // The hydration attempt must actually have hit the store, proving
        // `resolveTurnBriefingBuilder` didn't short-circuit before reaching it.
        #expect(failingThreadPersistence.fetchAttemptCount >= 1)
    }

    @Test("run returns a stream before a provider failure surfaces with typed identity")
    func providerFailureSurfacesThroughReturnedStream() async throws {
        let foreignError = NSError(domain: "FacadeRunForeign", code: 91)
        let mockLLM = MockLLMService()
        mockLLM.stubbedStream = AsyncThrowingStream { continuation in
            continuation.finish(throwing: foreignError)
        }
        let kit = PositronicKit(configuration: .init(
            provider: .init(languageModel: mockLLM),
            persistence: .inMemory()
        ))
        let thread = try await kit.threadManager.createThread()

        let stream = try await kit.run(TurnRequest(
            threadID: thread.id,
            message: "fail during provider streaming"
        ))

        do {
            _ = try await stream.collect()
            Issue.record("Expected the returned stream to surface the provider failure")
        } catch let error as PipelineError {
            guard case let .stageFailed(_, underlying) = error else {
                Issue.record("Expected PipelineError.stageFailed, got \(error)")
                return
            }
            let streamError = try #require(underlying as? LLMStreamError)
            #expect(streamError.errorDomain == PKErrorDomain.llm)
            #expect(streamError.errorCode == 1005)
            let foreignNSError = streamError.underlyingError as NSError
            #expect(foreignNSError.domain == foreignError.domain)
            #expect(foreignNSError.code == foreignError.code)
            let identity = TurnEvent.ErrorIdentity.extracting(from: error)
            #expect(identity?.domain == PKErrorDomain.llm)
            #expect(identity?.code == 1005)
        } catch {
            Issue.record("Expected a typed pipeline provider failure, got \(error)")
        }
    }
}
