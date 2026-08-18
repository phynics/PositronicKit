// swiftlint:disable file_length
import Foundation
import PKTestSupport
@testable import PKShared
import PKUtilities
@testable import PositronicKit
import Synchronization
import Testing

@Suite("Facade one-shot operations")
// swiftlint:disable:next type_body_length
struct FacadeOneShotTests {
    @Test("complete assembles streamed text without persisting a thread turn")
    func completeIsThreadFree() async throws {
        let llm = MockLLMService()
        llm.stubbedStream = Self.stream(contents: ["hel", "lo"])
        let persistence = PositronicKit.PersistenceConfiguration(
            messageStore: InMemoryMessageStore(),
            threadPersistence: InMemoryThreadPersistence(),
            workspacePersistence: InMemoryWorkspacePersistence(),
            memoryStore: InMemoryMemoryStore(),
            toolPersistence: InMemoryToolPersistence(),
            agentInstanceStore: InMemoryAgentInstanceStore(),
            requestOriginStore: InMemoryRequestOriginStore()
        )
        let kit = PositronicKit(configuration: .init(
            provider: .init(languageModel: llm),
            persistence: persistence
        ))

        let result = try await kit.complete("hi")

        #expect(result == "hello")
        #expect(try await persistence.messageStore.fetchMessages(for: UUID()).isEmpty)
        #expect(try await persistence.threadPersistence.fetchAllThreads(includeArchived: true).isEmpty)
        #expect(try await persistence.workspacePersistence.fetchAllWorkspaces().isEmpty)
        #expect(try await persistence.toolPersistence.fetchTools(forWorkspaces: []).isEmpty)
        #expect(try await persistence.agentInstanceStore.fetchAllAgentInstances().isEmpty)
        #expect(try await persistence.requestOriginStore.fetchAllOrigins().isEmpty)
    }

    @Test("stream exposes provider events without persistence")
    func streamIsThreadFree() async throws {
        let llm = MockLLMService()
        llm.stubbedStream = Self.stream(contents: ["one", "two"])
        let messageStore = InMemoryMessageStore()
        let threadPersistence = InMemoryThreadPersistence()
        let kit = PositronicKit(configuration: .init(
            provider: .init(languageModel: llm),
            persistence: .init(
                messageStore: messageStore,
                threadPersistence: threadPersistence
            )
        ))

        let events = try await kit.stream("hi").collect()

        #expect(events.compactMap { $0.choices.first?.delta.content } == ["one", "two"])
        #expect(try await messageStore.fetchMessages(for: UUID()).isEmpty)
        #expect(try await threadPersistence.fetchAllThreads(includeArchived: true).isEmpty)
    }

    @Test("abandoning one-shot iteration cancels the provider exactly once")
    func abandoningOneShotIterationCancelsProviderOnce() async throws {
        let probe = OneShotTerminationProbe()
        let llm = MockLLMService()
        llm.stubbedStream = Self.cancellableProviderStream(probe: probe, initialContent: "first")
        let kit = Self.makeKit(languageModel: llm)

        let consumer = Task {
            let stream = kit.stream("hi")
            var iterator = stream.makeAsyncIterator()
            return try await iterator.next()?.choices.first?.delta.content
        }
        defer {
            consumer.cancel()
            probe.releaseAll()
        }

        await probe.waitUntilStarted()
        let firstContent = try await consumer.value
        #expect(firstContent == "first")
        await probe.waitUntilTerminated()

        #expect(probe.terminationCount == 1)
    }

    @Test("one-shot result forwards parameters and exposes terminal metadata")
    func oneShotResultForwardsParametersAndMetadata() async throws {
        let llm = MockLLMService()
        let usage = LLMTokenUsage(promptTokens: 3, completionTokens: 2, totalTokens: 5)
        llm.mockClient.nextRawStreamChunks = [[
            LLMStreamChunk(
                id: "response-1",
                model: "test-model",
                choices: [LLMStreamChoice(
                    index: 0,
                    delta: LLMStreamDelta(content: "hello"),
                    finishReason: "stop"
                )],
                usage: usage
            )
        ]]
        let kit = PositronicKit(configuration: .init(
            provider: .init(languageModel: llm),
            persistence: .init(
                messageStore: InMemoryMessageStore(),
                threadPersistence: InMemoryThreadPersistence()
            )
        ))
        let parameters = GenerationParameters(temperature: 0.2, maxTokens: 12)

        let result = try await kit.completeResult("hi", generationParameters: parameters)

        #expect(result.content == "hello")
        #expect(result.finishReason == "stop")
        #expect(result.usage == usage)
        #expect(result.id == "response-1")
        #expect(result.model == "test-model")
        #expect(llm.mockClient.lastParameters == parameters)
    }

    @Test("one-shot idle timeout terminates a stalled stream")
    func oneShotIdleTimeout() async throws {
        let llm = MockLLMService()
        llm.stubbedStream = AsyncThrowingStream { _ in }
        let kit = PositronicKit(configuration: .init(
            provider: .init(languageModel: llm),
            persistence: .init(
                messageStore: InMemoryMessageStore(),
                threadPersistence: InMemoryThreadPersistence()
            )
        ))

        do {
            _ = try await kit.completeResult("hi", idleTimeout: 0.01)
            Issue.record("Expected the stalled one-shot stream to time out")
        } catch let error as ChatEngineError {
            guard case let .streamTimedOut(timeout) = error else {
                Issue.record("Expected stream timeout, got \(error)")
                return
            }
            #expect(timeout == 0.01)
        }
    }

    @Test("one-shot cancellation terminates promptly")
    func oneShotCancellation() async throws {
        let probe = OneShotTerminationProbe()
        let llm = MockLLMService()
        llm.stubbedStream = Self.cancellableProviderStream(probe: probe)
        let kit = PositronicKit(configuration: .init(
            provider: .init(languageModel: llm),
            persistence: .init(
                messageStore: InMemoryMessageStore(),
                threadPersistence: InMemoryThreadPersistence()
            )
        ))
        let task = Task {
            try await kit.completeResult("hi", idleTimeout: 60)
        }
        defer {
            task.cancel()
            probe.releaseAll()
        }

        await probe.waitUntilStarted()
        task.cancel()
        await probe.waitUntilTerminated()

        do {
            _ = try await task.value
            Issue.record("Expected one-shot cancellation to throw")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }
        #expect(probe.terminationCount == 1)
    }

    @Test("one-shot foreign provider errors retain wrapper and underlying identity")
    func oneShotForeignProviderErrorIdentity() async throws {
        let foreignError = NSError(domain: "FacadeOneShotForeign", code: 73)
        let llm = MockLLMService()
        llm.stubbedStream = AsyncThrowingStream { continuation in
            continuation.finish(throwing: foreignError)
        }
        let kit = Self.makeKit(languageModel: llm)

        do {
            _ = try await kit.complete("hi")
            Issue.record("Expected the foreign provider error to throw")
        } catch let error as LLMStreamError {
            #expect(error.errorDomain == PKErrorDomain.llm)
            #expect(error.errorCode == 1005)
            #expect((error.underlyingError as NSError) === foreignError)
        } catch {
            Issue.record("Expected LLMStreamError.providerStreamFailed, got \(error)")
        }
    }

    @Test("complete(_:structuredOutput:) passes the request through to the language model")
    func completeStructuredOutputPassesRequestThrough() async throws {
        let llm = MockLLMService()
        try await llm.updateConfiguration(.fixture(activeProvider: .openAICompatible))
        llm.mockClient.nextChunks = [[#"{"tags":["swift"]}"#]]
        let kit = PositronicKit(configuration: .init(
            provider: .init(languageModel: llm),
            persistence: PositronicKit.PersistenceConfiguration(
                messageStore: InMemoryMessageStore(),
                threadPersistence: InMemoryThreadPersistence(),
                workspacePersistence: InMemoryWorkspacePersistence(),
                memoryStore: InMemoryMemoryStore(),
                toolPersistence: InMemoryToolPersistence(),
                agentInstanceStore: InMemoryAgentInstanceStore(),
                requestOriginStore: InMemoryRequestOriginStore()
            )
        ))

        _ = try await kit.complete("extract tags", structuredOutput: .jsonObject)

        #expect(llm.mockClient.lastResponseFormat == .jsonObject)
        #expect(llm.mockClient.lastMessages == [LLMMessage(role: .user, content: "extract tags")])
    }

    @Test("structured complete forwards per-call generation parameters")
    func structuredCompleteForwardsPerCallGenerationParameters() async throws {
        let llm = MockLLMService()
        llm.mockClient.nextChunks = [[#"{"tags":["swift"]}"#]]
        let kit = Self.makeKit(languageModel: llm)
        let parameters = GenerationParameters(temperature: 0.2, maxTokens: 24)

        _ = try await kit.complete(
            "extract tags",
            structuredOutput: .jsonObject,
            generationParameters: parameters
        )

        #expect(llm.mockClient.lastParameters == parameters)
    }

    @Test("structured complete uses runtime generation parameters by default")
    func structuredCompleteUsesDefaultGenerationParameters() async throws {
        let llm = MockLLMService()
        llm.mockClient.nextChunks = [[#"{"tags":["swift"]}"#]]
        let defaults = GenerationParameters(temperature: 0.7, maxTokens: 48)
        let kit = Self.makeKit(languageModel: llm, generationParameters: defaults)

        _ = try await kit.complete("extract tags", structuredOutput: .jsonObject)

        #expect(llm.mockClient.lastParameters == defaults)
    }

    @Test("structured complete times out when the provider stream stays idle")
    func structuredCompleteIdleTimeout() async throws {
        let llm = MockLLMService()
        llm.stubbedStream = AsyncThrowingStream { _ in }
        let kit = Self.makeKit(languageModel: llm)

        do {
            _ = try await kit.complete(
                "extract tags",
                structuredOutput: .jsonObject,
                idleTimeout: 0.01
            )
            Issue.record("Expected the stalled structured stream to time out")
        } catch let error as ChatEngineError {
            guard case let .streamTimedOut(timeout) = error else {
                Issue.record("Expected stream timeout, got \(error)")
                return
            }
            #expect(timeout == 0.01)
        }
    }

    @Test("structured complete propagates cancellation without wrapping")
    func structuredCompleteCancellation() async throws {
        let probe = OneShotTerminationProbe()
        let llm = MockLLMService()
        llm.stubbedStream = Self.cancellableProviderStream(probe: probe)
        let kit = Self.makeKit(languageModel: llm)
        let task = Task {
            try await kit.complete(
                "extract tags",
                structuredOutput: .jsonObject,
                idleTimeout: 60
            )
        }
        defer {
            task.cancel()
            probe.releaseAll()
        }

        await probe.waitUntilStarted()
        task.cancel()
        await probe.waitUntilTerminated()

        do {
            _ = try await task.value
            Issue.record("Expected structured one-shot cancellation to throw")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }
        #expect(probe.terminationCount == 1)
    }

    @Test("structured complete wraps foreign provider stream errors")
    func structuredCompleteWrapsForeignProviderError() async throws {
        let llm = MockLLMService()
        llm.stubbedStream = AsyncThrowingStream { continuation in
            continuation.finish(throwing: ForeignStructuredProviderError())
        }
        let kit = Self.makeKit(languageModel: llm)

        do {
            _ = try await kit.complete("extract tags", structuredOutput: .jsonObject)
            Issue.record("Expected the foreign provider error to throw")
        } catch let LLMStreamError.providerStreamFailed(underlying) {
            #expect(underlying is ForeignStructuredProviderError)
        } catch {
            Issue.record("Expected LLMStreamError.providerStreamFailed, got \(error)")
        }
    }

    @Test("complete(_:structuredOutput:) assembles the JSON payload from content deltas")
    func completeStructuredOutputAssemblesContentDeltaPayload() async throws {
        let llm = MockLLMService()
        try await llm.updateConfiguration(.fixture(activeProvider: .openAICompatible))
        llm.mockClient.nextChunks = [[#"{"tags":["#, #""swift"]}"#]]
        let kit = PositronicKit(configuration: .init(
            provider: .init(languageModel: llm),
            persistence: PositronicKit.PersistenceConfiguration(
                messageStore: InMemoryMessageStore(),
                threadPersistence: InMemoryThreadPersistence(),
                workspacePersistence: InMemoryWorkspacePersistence(),
                memoryStore: InMemoryMemoryStore(),
                toolPersistence: InMemoryToolPersistence(),
                agentInstanceStore: InMemoryAgentInstanceStore(),
                requestOriginStore: InMemoryRequestOriginStore()
            )
        ))

        let result = try await kit.complete("extract tags", structuredOutput: .jsonObject)

        #expect(result == #"{"tags":["swift"]}"#)
    }

    @Test("complete(_:structuredOutput:) assembles the JSON payload from a synthetic tool call")
    func completeStructuredOutputAssemblesSyntheticToolCallPayload() async throws {
        let llm = MockLLMService()
        try await llm.updateConfiguration(.fixture(activeProvider: .anthropic))
        llm.mockClient = MockLLMClient(structuredOutputAdapter: DefaultStructuredOutputAdapter())
        llm.mockClient.nextRawStreamChunks = [[
            ChatStreamResultFactory.toolCallChunk(calls: [
                MockToolCall(id: "structured-call", name: "emit_structured_response", arguments: "{" + #""tags":["#)
            ]),
            ChatStreamResultFactory.toolCallChunk(calls: [
                MockToolCall(id: "structured-call", name: "emit_structured_response", arguments: #""swift"]}"#)
            ]),
        ]]
        let kit = PositronicKit(configuration: .init(
            provider: .init(languageModel: llm),
            persistence: PositronicKit.PersistenceConfiguration(
                messageStore: InMemoryMessageStore(),
                threadPersistence: InMemoryThreadPersistence(),
                workspacePersistence: InMemoryWorkspacePersistence(),
                memoryStore: InMemoryMemoryStore(),
                toolPersistence: InMemoryToolPersistence(),
                agentInstanceStore: InMemoryAgentInstanceStore(),
                requestOriginStore: InMemoryRequestOriginStore()
            )
        ))

        let result = try await kit.complete(
            "extract tags",
            structuredOutput: .jsonSchema(StructuredOutputFixtures.tagSchemaDefinition())
        )

        #expect(result == #"{"tags":["swift"]}"#)
        let decoded = try StructuredOutputDecoder.decode([String: [String]].self, from: result)
        #expect(decoded["tags"] == ["swift"])
    }

    @Test("complete(_:structuredOutput:) rejects an empty successful stream")
    func completeStructuredOutputRejectsEmptyStream() async throws {
        let llm = MockLLMService()
        try await llm.updateConfiguration(.fixture(activeProvider: .openAICompatible))
        llm.mockClient.nextChunks = [[]]
        let kit = PositronicKit(configuration: .init(
            provider: .init(languageModel: llm),
            persistence: PositronicKit.PersistenceConfiguration(
                messageStore: InMemoryMessageStore(),
                threadPersistence: InMemoryThreadPersistence()
            )
        ))

        do {
            _ = try await kit.complete("extract tags", structuredOutput: .jsonObject)
            Issue.record("Expected an empty structured response to throw")
        } catch let error as LLMServiceError {
            #expect(error == .emptyResponse(provider: LLMProvider.openAICompatible.rawValue))
        }
    }

    private static func stream(contents: [String]) -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { continuation in
            for content in contents {
                continuation.yield(LLMStreamChunk(
                    id: "test",
                    model: "test",
                    choices: [LLMStreamChoice(index: 0, delta: LLMStreamDelta(content: content))]
                ))
            }
            continuation.finish()
        }
    }

    private static func makeKit(
        languageModel: MockLLMService,
        generationParameters: GenerationParameters? = nil
    ) -> PositronicKit {
        PositronicKit(configuration: .init(
            provider: .init(languageModel: languageModel),
            persistence: .init(
                messageStore: InMemoryMessageStore(),
                threadPersistence: InMemoryThreadPersistence()
            ),
            generationParameters: generationParameters
        ))
    }

    private static func cancellableProviderStream(
        probe: OneShotTerminationProbe,
        initialContent: String? = nil
    ) -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { continuation in
            continuation.onTermination = { @Sendable _ in
                probe.recordTermination()
            }
            probe.markStarted()
            if let initialContent {
                continuation.yield(ChatStreamResultFactory.textChunk(initialContent))
            }
        }
    }
}

private struct ForeignStructuredProviderError: Error {}

private final class OneShotTerminationProbe: Sendable {
    private let started = FacadeTestSignal()
    private let terminated = FacadeTestSignal()
    private let count = Mutex(0)

    var terminationCount: Int {
        count.withLock { $0 }
    }

    func markStarted() {
        started.signal()
    }

    func waitUntilStarted() async {
        await started.wait()
    }

    func recordTermination() {
        count.withLock { $0 += 1 }
        terminated.signal()
    }

    func waitUntilTerminated() async {
        await terminated.wait()
    }

    func releaseAll() {
        started.signal()
        terminated.signal()
    }
}

private final class FacadeTestSignal: Sendable {
    private struct State {
        var isSignaled = false
        var waiter: CheckedContinuation<Void, Never>?
    }

    private let state = Mutex(State())

    func wait() async {
        await withCheckedContinuation { continuation in
            let shouldResume = state.withLock { state in
                guard !state.isSignaled else { return true }
                precondition(state.waiter == nil)
                state.waiter = continuation
                return false
            }
            if shouldResume {
                continuation.resume()
            }
        }
    }

    func signal() {
        let waiter = state.withLock { state in
            guard !state.isSignaled else { return nil as CheckedContinuation<Void, Never>? }
            state.isSignaled = true
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume()
    }
}
