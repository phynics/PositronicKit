import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Network)
import Network
#endif
import JSONSchemaBuilder
import PKShared
import PKTestSupport
@testable import PKAnthropicProvider
@testable import PKOllamaProvider
@testable import PKOpenAIProvider
@testable import PKOpenRouterProvider
@testable import PositronicKit
import OpenAI
import Synchronization
import Testing

@Suite("Structured output preparation order")
@MainActor
struct StructuredOutputPreparationTests {
    private static let registeredAdapters: Void = {
        _ = PKOpenAIProvider.makeLanguageModel(configuration: .init(provider: .openAI))
        _ = PKOpenRouterProvider.makeLanguageModel(configuration: .init(provider: .openRouter))
        _ = PKOllamaProvider.makeLanguageModel(configuration: .init(provider: .ollama))
        _ = PKAnthropicProvider.makeLanguageModel(configuration: .init(provider: .anthropic))
    }()

    init() {
        Self.registeredAdapters
    }

    @Test("Unified preparation matches provider behavior across output modes")
    func unifiedPreparationMatchesProviderBehavior() throws {
        let baseMessages = [LLMMessage(role: .user, content: "Extract tags")]
        let baseTool = LLMToolDefinition(name: "existing_tool", description: "existing")
        let schema = StructuredOutputFixtures.tagSchemaDefinition()

        for provider in [LLMProvider.openAI, .openRouter, .ollama, .openAICompatible, .anthropic] {
            for output in [StructuredOutputRequest.jsonObject, .jsonSchema(schema)] {
                let prepared = StructuredOutputExecution.prepareRequest(
                    messages: baseMessages,
                    tools: [baseTool],
                    provider: provider,
                    output: output
                )

                #expect(prepared.messages.count == 1)
                #expect(prepared.tools?.first?.name == baseTool.name)

                switch (provider, output) {
                case (_, .jsonObject):
                    #expect(prepared.messages.first == baseMessages.first)
                    #expect(prepared.responseFormat == .jsonObject)
                    #expect(prepared.promptAugmentation == nil)
                    #expect(prepared.toolChoice == nil)
                    #expect(prepared.syntheticToolName == nil)
                    #expect(prepared.tools?.count == 1)
                    #expect(prepared.tools?.first?.name == baseTool.name)
                    #expect(prepared.tools?.first?.description == baseTool.description)
                case let (.openAI, .jsonSchema(schema)),
                    let (.openRouter, .jsonSchema(schema)):
                    #expect(prepared.messages.first == baseMessages.first)
                    guard case let .jsonSchema(responseSchema)? = prepared.responseFormat else {
                        Issue.record("Expected native schema response format for \(provider)")
                        continue
                    }
                    #expect(responseSchema.name == schema.name)
                    #expect(responseSchema.description == schema.description)
                    #expect(responseSchema.strict == schema.strict)
                    #expect(responseSchema.schema != nil)
                    #expect(prepared.promptAugmentation == nil)
                    #expect(prepared.toolChoice == nil)
                    #expect(prepared.syntheticToolName == nil)
                    #expect(prepared.tools?.count == 1)
                    #expect(prepared.tools?.first?.name == baseTool.name)
                    #expect(prepared.tools?.first?.description == baseTool.description)
                case let (.ollama, .jsonSchema(schema)):
                    guard case let .jsonSchema(responseSchema)? = prepared.responseFormat else {
                        Issue.record("Expected Ollama schema response format")
                        continue
                    }
                    #expect(responseSchema.name == schema.name)
                    #expect(responseSchema.description == schema.description)
                    #expect(responseSchema.strict == schema.strict)
                    #expect(responseSchema.schema != nil)
                    #expect(prepared.promptAugmentation?.contains("Schema name: \(schema.name)") == true)
                    #expect(prepared.promptAugmentation?.contains("JSON Schema") == true)
                    #expect(prepared.messages.last?.content.contains("Schema name: \(schema.name)") == true)
                    #expect(prepared.toolChoice == nil)
                    #expect(prepared.syntheticToolName == nil)
                    #expect(prepared.tools?.count == 1)
                    #expect(prepared.tools?.first?.name == baseTool.name)
                    #expect(prepared.tools?.first?.description == baseTool.description)
                // Anthropic shares the openAICompatible synthetic-tool branch (no response_format
                // equivalent in the Messages API).
                case let (.openAICompatible, .jsonSchema(schema)),
                    let (.anthropic, .jsonSchema(schema)):
                    #expect(prepared.messages.first == baseMessages.first)
                    #expect(prepared.responseFormat == nil)
                    #expect(prepared.promptAugmentation == nil)
                    #expect(prepared.toolChoice == LLMToolChoice.function("emit_structured_response"))
                    #expect(prepared.syntheticToolName == "emit_structured_response")
                    #expect(prepared.messages == baseMessages)
                    #expect(prepared.tools?.contains(where: { $0.name == "emit_structured_response" }) == true)
                    #expect(prepared.tools?.contains(where: { $0.name == baseTool.name }) == true)
                    #expect(prepared.tools?.count == 2)
                    #expect(prepared.tools?.last?.name == "emit_structured_response")
                    if let tool = prepared.tools?.last {
                        #expect(tool.description?.contains(schema.name) == true)
                        #expect(tool.parameters != nil)
                        #expect(tool.strict == schema.strict)
                    }
                }
            }
        }
    }

    private func makeSchema() throws -> StructuredOutputSchema {
        let request = try SidecarSchemaComposer.compose(directives: [
            .init(name: "route", instruction: "r", schema: JSONString().definition(), streaming: .buffered, timing: .beforeResponse),
            .init(name: "title", instruction: "t", schema: JSONString().definition(), streaming: .buffered),
            .init(name: "tone", instruction: "n", schema: JSONString().definition(), streaming: .buffered),
        ])
        guard case let .jsonSchema(schema) = request else {
            throw NSError(domain: "StructuredOutputPreparationTests", code: 1)
        }
        return schema
    }

    private func assertRootKeyOrder(_ body: String, source: String) {
        guard let section = rootPropertiesSection(in: body),
              let priorityIndex = section.range(of: #""priority_sidecar_payload""#)?.lowerBound,
              let responseIndex = section.range(of: #""response""#)?.lowerBound,
              let sidecarIndex = section.range(of: #""sidecar_payload""#)?.lowerBound else {
            Issue.record("Missing sidecar root key in \(source) request body: \(body)")
            return
        }
        #expect(priorityIndex < responseIndex)
        #expect(responseIndex < sidecarIndex)
    }

    private func rootPropertiesSection(in body: String) -> String? {
        guard let start = body.range(of: #""properties":{"#)?.upperBound else {
            return nil
        }
        return String(body[start...])
    }

    @Test("OpenAI response_format preserves nested sidecar root order")
    func openAIResponseFormatPreservesOrder() throws {
        let schema = try makeSchema()
        let query = ChatQuery(
            messages: [LLMMessage(role: .user, content: "hello").toOpenAIMessageParam()],
            model: "gpt-4o",
            responseFormat: LLMResponseFormat.jsonSchema(.init(
                name: schema.name,
                description: schema.description,
                schema: schema.schema,
                strict: schema.strict
            )).toOpenAIResponseFormat(),
            stream: true
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let body = String(decoding: try encoder.encode(query), as: UTF8.self)
        assertRootKeyOrder(body, source: "OpenAI")
    }

    @Test("OpenRouter response_format preserves nested sidecar root order")
    func openRouterResponseFormatPreservesOrder() async throws {
        let transport = CapturingTransport { _ in
            .lines([
                #"data: {"id":"chunk-1","model":"openai/gpt-4o","choices":[{"index":0,"delta":{"role":"assistant","content":"hi"}}]}"#,
                "data: [DONE]",
            ], HTTPURLResponse(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"])!)
        }

        let client = OpenRouterClient(apiKey: "secret", transport: transport)
        let schema = try makeSchema()
        let stream = await client.chatStream(
            messages: [LLMMessage(role: .user, content: "hello")],
            tools: nil,
            toolChoice: nil,
            responseFormat: .jsonSchema(.init(
                name: schema.name,
                description: schema.description,
                schema: schema.schema,
                strict: schema.strict
            )),
            generationParameters: nil
        )
        _ = try await stream.collect()

        let request = try #require(await transport.recordedRequests().first)
        let body = try #require(request.httpBody.map { String(decoding: $0, as: UTF8.self) })
        assertRootKeyOrder(body, source: "OpenRouter")
    }

    @Test("Ollama format preserves nested sidecar root order")
    func ollamaFormatPreservesOrder() async throws {
        let transport = CapturingTransport { _ in
            .lines([
                #"{"model":"llama3.1","message":{"role":"assistant","content":"hi"},"done":false}"#,
                #"{"model":"llama3.1","message":{"role":"assistant","content":""},"done":true,"prompt_eval_count":1,"eval_count":1}"#,
            ], HTTPURLResponse(url: URL(string: "http://localhost:11434/api/chat")!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/x-ndjson"])!)
        }

        let client = OllamaClient(endpoint: "http://localhost:11434", modelName: "llama3.1", transport: transport)
        let schema = try makeSchema()
        let stream = await client.chatStream(
            messages: [LLMMessage(role: .user, content: "hello")],
            tools: nil,
            toolChoice: nil,
            responseFormat: .jsonSchema(.init(
                name: schema.name,
                description: schema.description,
                schema: schema.schema,
                strict: schema.strict
            )),
            generationParameters: nil
        )
        _ = try await stream.collect()

        let request = try #require(await transport.recordedRequests().first)
        let body = try #require(request.httpBody.map { String(decoding: $0, as: UTF8.self) })
        assertRootKeyOrder(body, source: "Ollama")
    }

    @Test("Synthetic tool parameters preserve nested sidecar root order")
    func syntheticToolParametersPreserveOrder() async throws {
        let transport = CapturingTransport { _ in
            .lines([
                #"data: {"id":"chunk-1","model":"openai/gpt-4o","choices":[{"index":0,"delta":{"role":"assistant","content":"hi"}}]}"#,
                "data: [DONE]",
            ], HTTPURLResponse(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"])!)
        }

        let client = OpenRouterClient(apiKey: "secret", transport: transport)
        let schema = try makeSchema()
        let tool = LLMToolDefinition(
            name: "emit_structured_response",
            description: "Emit structured response",
            parameters: schema.schema,
            strict: true
        )
        let stream = await client.chatStream(
            messages: [LLMMessage(role: .user, content: "hello")],
            tools: [tool],
            toolChoice: .function("emit_structured_response"),
            responseFormat: nil,
            generationParameters: nil
        )
        _ = try await stream.collect()

        let request = try #require(await transport.recordedRequests().first)
        let body = try #require(request.httpBody.map { String(decoding: $0, as: UTF8.self) })
        assertRootKeyOrder(body, source: "Synthetic tool")
    }
}

private actor CapturingTransport: ProviderHTTPTransport {
    enum Response {
        case lines([String], HTTPURLResponse)
        case data(Data, HTTPURLResponse)
    }

    private var requestsStorage: [URLRequest] = []
    private let responder: @Sendable (URLRequest) -> Response

    init(responder: @escaping @Sendable (URLRequest) -> Response) {
        self.responder = responder
    }

    func recordedRequests() -> [URLRequest] {
        requestsStorage
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requestsStorage.append(request)
        switch responder(request) {
        case let .data(data, response):
            return (data, response)
        case let .lines(lines, response):
            return (Data(lines.joined(separator: "\n").utf8), response)
        }
    }

    func lines(for request: URLRequest) async throws -> (AsyncThrowingStream<String, Error>, URLResponse) {
        requestsStorage.append(request)
        switch responder(request) {
        case let .lines(lines, response):
            return (
                AsyncThrowingStream { continuation in
                    for line in lines {
                        continuation.yield(line)
                    }
                    continuation.finish()
                },
                response
            )
        case let .data(data, response):
            return (
                AsyncThrowingStream { continuation in
                    continuation.yield(String(decoding: data, as: UTF8.self))
                    continuation.finish()
                },
                response
            )
        }
    }
}
