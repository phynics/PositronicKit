import Foundation
import PKContracts
import PKTestSupport
import PKUtilities
@testable import PKOpenAIProvider
@testable import PKOpenRouterProvider
@testable import PositronicKit
import Testing

@Suite("Chat Completions failure contracts", .tags(.integration))
struct ChatCompletionsFailureTests {
    enum Provider: String, CaseIterable, Sendable {
        case openAI = "OpenAI"
        case openRouter = "OpenRouter"

        func client(transport: ScriptedProviderHTTPTransport) -> any LLMClientProtocol {
            switch self {
            case .openAI:
                OpenAIClient(apiKey: "test", maxRetries: 0, transport: transport, api: .chatCompletions)
            case .openRouter:
                OpenRouterClient(apiKey: "test", maxRetries: 0, transport: transport)
            }
        }
    }

    enum Recovery: CaseIterable, Sendable {
        case emptyChoices
        case missingCalls
        case emptyCalls
        case stopped

        var body: Data {
            let choices: String
            switch self {
            case .emptyChoices:
                choices = "[]"
            case .missingCalls:
                choices = #"[{"index":0,"finish_reason":"tool_calls","message":{"role":"assistant","content":null}}]"#
            case .emptyCalls:
                choices = #"[{"index":0,"finish_reason":"tool_calls","message":{"role":"assistant","content":null,"tool_calls":[]}}]"#
            case .stopped:
                choices = #"[{"index":0,"finish_reason":"stop","message":{"role":"assistant","content":"done"}}]"#
            }
            return Data("{\"id\":\"recovery\",\"model\":\"test\",\"choices\":\(choices)}".utf8)
        }
    }

    private static let toolTerminal = #"data: {"id":"stream","model":"test","choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}"#

    private func recoveryTransport(_ recovery: Recovery) -> ScriptedProviderHTTPTransport {
        ScriptedProviderHTTPTransport(responses: [
            .linesResponse([Self.toolTerminal, "data: [DONE]"]),
            .dataResponse(recovery.body),
        ])
    }

    @Test("empty tool recovery fails instead of ending successfully", arguments: Provider.allCases, Recovery.allCases)
    func unusableRecoveryThrows(provider: Provider, recovery: Recovery) async throws {
        let transport = recoveryTransport(recovery)
        let stream = await provider.client(transport: transport).chatStream(
            messages: [.init(role: .user, content: "Use a tool")],
            tools: [.init(name: "lookup", description: "Look up a value")],
            toolChoice: .auto, responseFormat: nil, generationParameters: nil
        )

        await #expect(throws: LLMServiceError.unexpectedResponse(
            provider: provider.rawValue, reason: "tool-call recovery returned no usable tool calls"
        )) {
            for try await _ in stream {}
        }
        #expect(await transport.requestCount() == 2)
    }

    @Test("a malformed stream preserves earlier text and propagates a decoding failure", arguments: Provider.allCases)
    func malformedStreamFails(provider: Provider) async throws {
        let transport = ScriptedProviderHTTPTransport(lines: [
            #"data: {"id":"stream","model":"test","choices":[{"index":0,"delta":{"content":"partial"}}]}"#,
            "data: {bad json",
            Self.toolTerminal,
            "data: [DONE]",
        ])
        let stream = await provider.client(transport: transport).chatStream(
            messages: [.init(role: .user, content: "hello")],
            tools: nil, toolChoice: nil, responseFormat: nil, generationParameters: nil
        )
        var text = ""
        await #expect(throws: DecodingError.self) {
            for try await chunk in stream {
                text += chunk.choices.first?.delta.content ?? ""
            }
        }
        #expect(text == "partial")
        #expect(await transport.requestCount() == 1)
    }

    @Test("failed recovery commits a failed Turn", arguments: Provider.allCases)
    func failedRecoveryIsDurable(provider: Provider) async throws {
        let transport = recoveryTransport(.emptyCalls)
        let repository = InMemoryTimelineRuntimeRepository()
        let configuredProvider = ConfiguredLLMProvider(
            configuration: .fixture(
                endpoint: "https://example.com", modelName: "test", apiKey: "test",
                activeProvider: provider == .openAI ? .openAI : .openRouter
            ),
            client: provider.client(transport: transport)
        )
        let runtime = PKRuntime(configuration: .init(
            provider: configuredProvider,
            persistence: .init(runtimeRepository: repository)
        ))
        let timeline = try await runtime.timelines.create(title: "Failed tool recovery")
        let turn = try await timeline.startDirectTurn(
            "Use a tool", context: .init(systemInstructions: "")
        )
        let outcome = try await turn.outcome()
        guard case let .failed(message) = outcome else {
            Issue.record("Expected failed tool recovery, got \(outcome)")
            return
        }
        #expect(message.contains("tool-call recovery returned no usable tool calls"))
        let record = try #require(try await repository.fetchTurn(id: turn.id))
        #expect(record.isTerminal)
        #expect(record.outcome == outcome)
    }
}
