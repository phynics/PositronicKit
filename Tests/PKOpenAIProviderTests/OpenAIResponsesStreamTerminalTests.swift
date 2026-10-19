import Foundation
import Testing
@testable import PKOpenAIProvider
import PKContracts
import PKTestSupport
import PKUtilities
@testable import PositronicKit

/// Captured-SSE terminal coverage for the Responses streaming path (issue #369).
///
/// The Responses wire protocol requires every stream to end with exactly one terminal event
/// (`response.completed`, `response.incomplete`, `response.failed`, or a bare `error`). These
/// tests replay captured SSE bodies and assert that provider failures and truncations
/// propagate instead of yielding a clean successful EOF, that provider diagnostics are
/// preserved, and that the underlying Timeline Turn reaches a failed or faithfully-tagged
/// terminal rather than a fabricated clean completion.
@Suite("OpenAI Responses stream terminals", .serialized)
struct OpenAIResponsesStreamTerminalTests {
        private func terminalChunk(_ type: String, _ payload: String, responseID: String) -> LLMStreamChunk? {
        var accumulator = ResponsesStreamAccumulator()
        return ResponsesEvents.chunk(
            forEventType: type,
            payload: Data(payload.utf8),
            model: "gpt-4o",
            responseID: responseID,
            accumulator: &accumulator
        )
    }

    // MARK: - Pure terminal classification


    @Test("response.failed is classified with structured provider diagnostics")
    func failedTerminalCarriesDiagnostics() throws {
        let payload = #"{"type":"response.failed","response":{"id":"resp_f","status":"failed","error":{"code":"server_error","message":"The server had an error while processing your request."}}}"#
        let terminal = try #require(ResponsesEvents.terminalEvent(
            forEventType: "response.failed",
            payload: Data(payload.utf8)
        ))
        #expect(terminal == .failed(message: "response.failed: server_error: The server had an error while processing your request."))

        var accumulator = ResponsesStreamAccumulator()
        #expect(ResponsesEvents.chunk(
            forEventType: "response.failed",
            payload: Data(payload.utf8),
            model: "gpt-4o",
            responseID: "resp_f",
            accumulator: &accumulator
        ) == nil)
    }

    @Test("response.failed accepts the flat error shape and falls back to a sanitized snippet")
    func failedTerminalFlatShapeAndFallback() throws {
        let flat = try #require(ResponsesEvents.terminalEvent(
            forEventType: "response.failed",
            payload: Data(#"{"type":"response.failed","code":"model_error","message":"bad request shape"}"#.utf8)
        ))
        #expect(flat == .failed(message: "response.failed: model_error: bad request shape"))

        let fallback = try #require(ResponsesEvents.terminalEvent(
            forEventType: "response.failed",
            payload: Data("{\"type\":\"response.failed\",\"opaque\":true}".utf8)
        ))
        guard case let .failed(message) = fallback else {
            Issue.record("expected .failed terminal")
            return
        }
        #expect(message.hasPrefix("response.failed: "))
    }

    @Test("in-band error event maps to a provider error terminal")
    func inBandErrorEvent() throws {
        #expect(ResponsesEvents.terminalEvent(
            forEventType: "error",
            payload: Data(#"{"type":"error","code":"rate_limit_error","message":"Rate limit reached."}"#.utf8)
        ) == .providerError(message: "error: rate_limit_error: Rate limit reached."))
    }

    @Test("completed and non-terminal events classify correctly")
    func completedAndNonTerminalEvents() throws {
        #expect(ResponsesEvents.terminalEvent(
            forEventType: "response.completed",
            payload: Data(#"{"type":"response.completed","response":{"id":"resp_c","status":"completed"}}"#.utf8)
        ) == .completed)
        #expect(ResponsesEvents.terminalEvent(
            forEventType: "response.output_text.delta",
            payload: Data(#"{"type":"response.output_text.delta","delta":"hi"}"#.utf8)
        ) == nil)
        #expect(ResponsesEvents.terminalEvent(
            forEventType: "response.in_progress",
            payload: Data(#"{"type":"response.in_progress"}"#.utf8)
        ) == nil)
    }

    @Test("response.incomplete maps incomplete_details.reason to shared finish reasons")
    func incompleteReasonMapping() throws {
        // Real wire shape: the terminal event embeds the full response resource.
        let length = try #require(terminalChunk(
            "response.incomplete",
            #"{"type":"response.incomplete","response":{"id":"resp_i","status":"incomplete","incomplete_details":{"reason":"max_output_tokens"},"usage":{"input_tokens":10,"output_tokens":5,"total_tokens":15}}}"#,
            responseID: "resp_i"
        ))
        #expect(length.choices.first?.finishReason == "length")
        #expect(length.choices.first?.delta.content == nil)
        #expect(length.usage?.totalTokens == 15)

        let filter = try #require(terminalChunk(
            "response.incomplete",
            #"{"type":"response.incomplete","response":{"incomplete_details":{"reason":"content_filter"}}}"#,
            responseID: "resp_i"
        ))
        #expect(filter.choices.first?.finishReason == "content_filter")

        let passthrough = try #require(terminalChunk(
            "response.incomplete",
            #"{"type":"response.incomplete","response":{"incomplete_details":{"reason":"guardrail"}}}"#,
            responseID: "resp_i"
        ))
        #expect(passthrough.choices.first?.finishReason == "guardrail")

        let missing = try #require(terminalChunk(
            "response.incomplete",
            #"{"type":"response.incomplete"}"#,
            responseID: "resp_i"
        ))
        #expect(missing.choices.first?.finishReason == "incomplete")

        // The classifier reports the same mapping for the client's terminal gate.
        #expect(ResponsesEvents.terminalEvent(
            forEventType: "response.incomplete",
            payload: Data(#"{"type":"response.incomplete","response":{"incomplete_details":{"reason":"max_output_tokens"}}}"#.utf8)
        ) == .incomplete(.length))
        #expect(ResponsesEvents.terminalEvent(
            forEventType: "response.incomplete",
            payload: Data(#"{"type":"response.incomplete"}"#.utf8)
        ) == .incomplete(.other("incomplete")))
    }

    @Test("response.completed parses usage nested in the embedded response resource")
    func completedUsageNestedShape() throws {
        let chunk = try #require(terminalChunk(
            "response.completed",
            #"{"type":"response.completed","response":{"id":"resp_c","status":"completed","usage":{"input_tokens":10,"output_tokens":5,"total_tokens":15,"input_tokens_details":{"cached_tokens":4},"cache_write_tokens":6}}}"#,
            responseID: "resp_c"
        ))
        #expect(chunk.choices.first?.finishReason == "stop")
        let details = try #require(chunk.usage?.promptTokensDetails)
        #expect(details.cachedTokens == 4)
        #expect(details.cacheWriteTokens == 6)
    }

    // MARK: - Captured-SSE client behavior (scripted transport)

    @Test("failed terminal after partial text preserves partial chunks and throws provider diagnostics")
    func failedAfterPartialText() async throws {
        let transport = ScriptedProviderHTTPTransport(lines: [
            "data: {\"type\":\"response.output_text.delta\",\"response_id\":\"resp_a\",\"delta\":\"partial answer \"}",
            "data: {\"type\":\"response.output_text.delta\",\"response_id\":\"resp_a\",\"delta\":\"before failure\"}",
            "data: {\"type\":\"response.failed\",\"response\":{\"id\":\"resp_a\",\"status\":\"failed\",\"error\":{\"code\":\"server_error\",\"message\":\"The server had an error while processing your request.\"}}}",
        ])
        let client = OpenAIClient(
            apiKey: "secret-key", modelName: "gpt-4o", maxRetries: 0,
            transport: transport, api: .responses
        )
        let chunks = try await collectChunks(client: client)

        #expect(chunks.count == 2)
        #expect(chunks.compactMap { $0.choices.first?.delta.content }.joined() == "partial answer before failure")
        #expect(await transport.requestCount() == 1)
    }

    /// Consumes `chatStream`, collecting every successfully yielded chunk; the failing
    /// terminal aborts the `for try await` loop into the `catch`, so the collected prefix
    /// proves partial output is preserved alongside the surfaced error.
    private func collectChunks(client: OpenAIClient, expectedFailure: Bool = true) async throws -> [LLMStreamChunk] {
        let stream = await client.chatStream(
            messages: [.init(role: .user, content: "hello")],
            tools: nil,
            toolChoice: nil,
            responseFormat: nil,
            generationParameters: nil
        )
        var chunks: [LLMStreamChunk] = []
        do {
            for try await chunk in stream {
                chunks.append(chunk)
            }
            if expectedFailure {
                Issue.record("expected the stream to finish with an error")
            }
        } catch {
            if !expectedFailure {
                Issue.record("unexpected stream error: \(error)")
            }
        }
        return chunks
    }

    private func makeResponsesClient(_ lines: [String]) -> (OpenAIClient, ScriptedProviderHTTPTransport) {
        let transport = ScriptedProviderHTTPTransport(lines: lines)
        let client = OpenAIClient(
            apiKey: "secret-key", modelName: "gpt-4o", maxRetries: 0,
            transport: transport, api: .responses
        )
        return (client, transport)
    }

    @Test("premature EOF throws instead of completing and never retries")
    func prematureEOFThrows() async throws {
        let (client, transport) = makeResponsesClient([
            "data: {\"type\":\"response.output_text.delta\",\"response_id\":\"resp_b\",\"delta\":\"half\"}",
        ])
        let stream = await client.chatStream(
            messages: [.init(role: .user, content: "hello")],
            tools: nil,
            toolChoice: nil,
            responseFormat: nil,
            generationParameters: nil
        )
        await #expect(throws: LLMServiceError.unexpectedResponse(
            provider: "OpenAI",
            reason: "stream ended before a terminal response event"
        )) {
            var all: [LLMStreamChunk] = []
            for try await chunk in stream { all.append(chunk) }
        }
        #expect(await transport.requestCount() == 1)
    }

    @Test("incomplete terminal surfaces mapped finish reason and usage without throwing")
    func incompleteWithLengthTerminal() async throws {
        let (client, _) = makeResponsesClient([
            "data: {\"type\":\"response.output_text.delta\",\"response_id\":\"resp_c\",\"delta\":\"partial answer that hit the cap\"}",
            "data: {\"type\":\"response.incomplete\",\"response\":{\"id\":\"resp_c\",\"status\":\"incomplete\",\"incomplete_details\":{\"reason\":\"max_output_tokens\"},\"usage\":{\"input_tokens\":10,\"output_tokens\":5,\"total_tokens\":15}}}",
        ])
        let chunks = try await collectChunks(client: client, expectedFailure: false)

        #expect(chunks.first?.choices.first?.delta.content == "partial answer that hit the cap")
        let terminal = try #require(chunks.last)
        #expect(terminal.choices.first?.finishReason == "length")
        #expect(terminal.choices.first?.delta.content == nil)
        #expect(terminal.usage?.totalTokens == 15)
    }

    @Test("incomplete terminal with a non-length reason passes the reason through")
    func incompleteWithOtherReasonTerminal() async throws {
        let (client, _) = makeResponsesClient([
            "data: {\"type\":\"response.output_text.delta\",\"response_id\":\"resp_d\",\"delta\":\"blocked text\"}",
            "data: {\"type\":\"response.incomplete\",\"response\":{\"id\":\"resp_d\",\"status\":\"incomplete\",\"incomplete_details\":{\"reason\":\"guardrail\"}}}",
        ])
        let chunks = try await collectChunks(client: client, expectedFailure: false)
        let terminal = try #require(chunks.last)
        #expect(terminal.choices.first?.finishReason == "guardrail")
    }

    @Test("in-band error event after partial text throws provider diagnostics")
    func inBandErrorEventThrows() async throws {
        let (client, _) = makeResponsesClient([
            "data: {\"type\":\"response.output_text.delta\",\"response_id\":\"resp_e\",\"delta\":\"text\"}",
            "data: {\"type\":\"error\",\"code\":\"server_error\",\"message\":\"provider blew up\"}",
        ])
        let stream = await client.chatStream(
            messages: [.init(role: .user, content: "hello")],
            tools: nil,
            toolChoice: nil,
            responseFormat: nil,
            generationParameters: nil
        )
        await #expect(throws: LLMServiceError.unexpectedResponse(
            provider: "OpenAI",
            reason: "provider reported failure: error: server_error: provider blew up"
        )) {
            var all: [LLMStreamChunk] = []
            for try await chunk in stream { all.append(chunk) }
        }
    }

    @Test("valid completed terminal still ends clean")
    func completedStreamSanity() async throws {
        let (client, _) = makeResponsesClient([
            "data: {\"type\":\"response.output_text.delta\",\"response_id\":\"resp_g\",\"delta\":\"done\"}",
            "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_g\",\"status\":\"completed\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1,\"total_tokens\":2}}}",
        ])
        let chunks = try await collectChunks(client: client, expectedFailure: false)
        #expect(chunks.count == 2)
        #expect(chunks.last?.choices.first?.finishReason == "stop")
    }

    // MARK: - Runtime Turn terminal status

    private actor TurnOutcomeProbe: TurnOutcomeSink {
        private(set) var records: [TurnOutcomeRecord] = []

        func record(_ outcome: TurnOutcomeRecord) async throws {
            records.append(outcome)
        }
    }

    /// Assembles a runtime over `MockPersistenceService` whose only LLM provider is
    /// `OpenAIClient(.responses)` backed by the captured SSE lines.
    private func makeRuntime(_ lines: [String]) async throws -> (PKRuntime, TurnOutcomeProbe, MockPersistenceService, ScriptedProviderHTTPTransport) {
        let probe = TurnOutcomeProbe()
        let persistence = MockPersistenceService()
        let transport = ScriptedProviderHTTPTransport(lines: lines)
        let client = OpenAIClient(
            apiKey: "secret-key", modelName: "gpt-4o", maxRetries: 0,
            transport: transport, api: .responses
        )
        let provider = ConfiguredLLMProvider(
            configuration: LLMConfiguration.fixture(
                endpoint: "http://providers.test/v1",
                modelName: "gpt-4o",
                apiKey: "secret-key",
                activeProvider: .openAI
            ),
            client: client
        )
        let runtime = PKRuntime(configuration: .init(
            provider: provider,
            persistence: .init(
                runtimeRepository: persistence,
                workspacePersistence: persistence,
                agentStore: persistence,
                requestOriginStore: persistence
            ),
            runtime: .init(customization: .init(turnOutcomeSink: probe))
        ))
        return (runtime, probe, persistence, transport)
    }

    private static let failedStreamLines = [
        "data: {\"type\":\"response.output_text.delta\",\"delta\":\"partial answer \"}",
        "data: {\"type\":\"response.failed\",\"error\":{\"code\":\"server_error\",\"message\":\"The server had an error while processing your request.\"}}",
    ]

    @Test("failed terminal drives a durable failed Turn with partial text retained")
    func turnDurableFailedOutcome() async throws {
        let (runtime, probe, persistence, _) = try await makeRuntime(Self.failedStreamLines)
        let timeline = try await runtime.timelines.create(title: "Responses failed terminal")
        let turn = try await timeline.startDirectTurn(
            "Say something then blow up.",
            context: DirectTurnContext(systemInstructions: "")
        )

        let events = await turn.events().collect()

        // The streamed partial text remains a generation delta; the stream ends with the
        // surfaced error carrying the provider diagnostics and no completion event.
        #expect(events.contains { event in
            if case .delta(.generation(let text)) = event { return text == "partial answer " }
            return false
        })
        guard case let .error(lastError) = try #require(events.last) else {
            Issue.record("expected a terminal error event, got \(String(describing: events.last))")
            return
        }
        guard case let .error(message, _) = lastError else {
            Issue.record("unexpected error event shape: \(lastError)")
            return
        }
        #expect(message.contains("provider reported failure: response.failed: server_error: The server had an error while processing your request."))

        // The terminal outcome is durable: relayed through the sink and stored on the Turn.
        // `ErrorKit` prefixes the durable failure message with the throwing pipeline stage.
        let failureMessage = "Pipeline stage 'LLMStreamingStage' failed: "
            + "OpenAI returned an unexpected response: provider reported failure: "
            + "response.failed: server_error: The server had an error while processing your request."
        let record = try #require(await probe.records.last)
        #expect(record.timelineID == timeline.id)
        #expect(record.outcome == .failed(message: failureMessage))
        #expect(try await turn.outcome() == record.outcome)
        let durableRecord = try #require(try await persistence.fetchTurn(id: record.turnID))
        #expect(durableRecord.outcome == record.outcome)
        #expect(durableRecord.isTerminal)

        // The partial assistant text streamed before the failure is retained.
        let messages = try await persistence.fetchMessages(for: timeline.id)
        let partialAssistant = try #require(messages.first { $0.role == "assistant" })
        #expect(partialAssistant.content == "partial answer ")
        #expect(partialAssistant.toMessage().status == .partial)
    }

    @Test("incomplete terminal completes the Turn but records the truncation finish reason")
    func turnDurableIncompleteTerminal() async throws {
        let (runtime, _, persistence, _) = try await makeRuntime([
            "data: {\"type\":\"response.output_text.delta\",\"delta\":\"partial answer that hit the cap\"}",
            "data: {\"type\":\"response.incomplete\",\"response\":{\"id\":\"resp_inc\",\"status\":\"incomplete\",\"incomplete_details\":{\"reason\":\"max_output_tokens\"},\"usage\":{\"input_tokens\":10,\"output_tokens\":5,\"total_tokens\":15}}}",
        ])
        let timeline = try await runtime.timelines.create(title: "Responses incomplete terminal")
        let turn = try await timeline.startDirectTurn(
            "Write a long answer.",
            context: DirectTurnContext(systemInstructions: "")
        )

        let events = await turn.events().collect()

        guard case let .completion(lastCompletion) = try #require(events.last) else {
            Issue.record("expected a terminal completion event, got \(String(describing: events.last))")
            return
        }
        guard case let .generationCompleted(message, metadata) = lastCompletion else {
            Issue.record("unexpected completion event shape")
            return
        }
        // The terminal metadata records the truncation, not a clean stop.
        #expect(metadata.finishReason == "length")
        #expect(metadata.usage?.totalTokens == 15)
        #expect(message.content == "partial answer that hit the cap")

        // An incomplete terminal is still a valid terminal: the Turn completes, but the
        // durable assistant row preserves the truncated text and the `length` finish reason.
        let durableRecord = try #require(try await persistence.fetchTurn(id: turn.id))
        #expect(durableRecord.outcome == .completed)
        #expect(durableRecord.isTerminal)
        let messages = try await persistence.fetchMessages(for: timeline.id)
        let assistant = try #require(messages.first { $0.role == "assistant" })
        #expect(assistant.content == "partial answer that hit the cap")
        #expect(assistant.toMessage().status == nil)
    }

    @Test("abnormal EOF drives a durable failed Turn")
    func turnDurableAbnormalEOFOutcome() async throws {
        let (runtime, probe, persistence, _) = try await makeRuntime([
            "data: {\"type\":\"response.output_text.delta\",\"delta\":\"half\"}",
        ])
        let timeline = try await runtime.timelines.create(title: "Responses abnormal EOF")
        let turn = try await timeline.startDirectTurn(
            "Say something.",
            context: DirectTurnContext(systemInstructions: "")
        )

        let events = await turn.events().collect()

        guard case .error = try #require(events.last) else {
            Issue.record("expected a terminal error event, got \(String(describing: events.last))")
            return
        }
        let record = try #require(await probe.records.last)
        guard case .failed = record.outcome else {
            Issue.record("expected a failed outcome, got \(record.outcome)")
            return
        }
        let durableRecord = try #require(try await persistence.fetchTurn(id: record.turnID))
        #expect(durableRecord.outcome == record.outcome)
        #expect(durableRecord.isTerminal)
    }
}
