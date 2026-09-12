import Foundation
import JSONSchema
import JSONSchemaBuilder
import PKTestSupport
@testable import PKContracts
@testable import PositronicKit
import Testing

@Suite("Typed structured generation")
struct TypedStructuredGenerationTests {
    @Test("native structured generation decodes the response and forwards the generated schema")
    func nativeStructuredGeneration() async throws {
        let llm = MockLLMService()
        llm.mockClient.nextChunks = [[#"{"project_name":"PositronicKit","language":"Swift"}"#]]
        let persistence = PositronicKit.PersistenceConfiguration(
            runtimeRepository: InMemoryThreadRuntimeRepository(),
            workspacePersistence: InMemoryWorkspacePersistence(),
            toolPersistence: InMemoryToolPersistence(),
            agentStore: InMemoryAgentStore(),
            requestOriginStore: InMemoryRequestOriginStore()
        )
        let kit = PositronicKit(configuration: .init(
            provider: .init(languageModel: llm),
            persistence: persistence,
            generationParameters: GenerationParameters(temperature: 0.4, maxTokens: 64)
        ))

        let result = try await kit.model.generate(
            ProjectMetadata.self,
            from: "Extract the project metadata.",
            generationParameters: GenerationParameters(temperature: 0.1, maxTokens: 32),
            idleTimeout: 12
        )

        #expect(result == ProjectMetadata(projectName: "PositronicKit", language: "Swift"))
        guard case let .jsonSchema(schema) = llm.mockClient.lastResponseFormat else {
            Issue.record("Expected a native JSON Schema response format")
            return
        }
        #expect(schema.name == ProjectMetadata.defaultAnchor)
        #expect(schema.isStrict == true)
        let encodedSchema = try String(
            decoding: JSONEncoder().encode(schema.schema),
            as: UTF8.self
        )
        #expect(encodedSchema.contains("project_name"))
        #expect(!encodedSchema.contains("projectName"))
        #expect(llm.mockClient.lastParameters == GenerationParameters(temperature: 0.1, maxTokens: 32))

        #expect(try await persistence.runtimeRepository.fetchAllThreads(includeArchived: true).isEmpty)
        #expect(try await persistence.runtimeRepository.fetchMessages(for: UUID()).isEmpty)
        #expect(try await persistence.workspacePersistence.fetchAllWorkspaces().isEmpty)
        #expect(try await persistence.toolPersistence.fetchTools(forWorkspaces: []).isEmpty)
        #expect(try await persistence.agentStore.fetchAllAgents().isEmpty)
        #expect(try await persistence.requestOriginStore.fetchAllOrigins().isEmpty)
    }

    @Test("synthetic structured generation uses the existing tool adapter path")
    func syntheticStructuredGeneration() async throws {
        let llm = MockLLMService()
        try await llm.updateConfiguration(.fixture(activeProvider: .anthropic))
        llm.mockClient = MockLLMClient(structuredOutputAdapter: DefaultStructuredOutputAdapter())
        llm.mockClient.nextRawStreamChunks = [[
            GenerationStreamResultFactory.toolCallChunk(calls: [
                MockToolCall(
                    id: "structured-call",
                    name: "emit_structured_response",
                    arguments: "{\"project_name\":\"Positronic"
                )
            ]),
            GenerationStreamResultFactory.toolCallChunk(calls: [
                MockToolCall(
                    id: "structured-call",
                    name: "emit_structured_response",
                    arguments: "Kit\",\"language\":\"Swift\"}"
                )
            ]),
        ]]
        let kit = makeKit(languageModel: llm)

        let result = try await kit.model.generate(
            ProjectMetadata.self,
            from: "Extract the project metadata."
        )

        #expect(result == ProjectMetadata(projectName: "PositronicKit", language: "Swift"))
        #expect(llm.mockClient.lastResponseFormat == nil)
        #expect(llm.mockClient.lastTools?.first?.name == "emit_structured_response")
        #expect(llm.mockClient.lastToolChoice == .function("emit_structured_response"))
    }

    @Test("a custom decoder is passed through and can use explicit CodingKeys")
    func customDecoderAndCodingKeys() async throws {
        let llm = MockLLMService()
        llm.mockClient.nextChunks = [[#"{"wire_value":"decoded"}"#]]
        let kit = makeKit(languageModel: llm)
        let decoder = JSONDecoder()
        decoder.userInfo[.typedStructuredGenerationSuffix] = "!"

        let result = try await kit.model.generate(
            CustomDecodedPayload.self,
            from: "Extract the value.",
            decoder: decoder
        )

        #expect(result == CustomDecodedPayload(value: "decoded!"))
        guard case let .jsonSchema(schema) = llm.mockClient.lastResponseFormat else {
            Issue.record("Expected a JSON Schema response format")
            return
        }
        let encodedSchema = try String(
            decoding: JSONEncoder().encode(schema.schema),
            as: UTF8.self
        )
        #expect(encodedSchema.contains("wire_value"))
        #expect(schema.name == CustomDecodedPayload.defaultAnchor)
    }

    @Test("nil generation parameters use the runtime defaults")
    func defaultGenerationParameters() async throws {
        let llm = MockLLMService()
        llm.mockClient.nextChunks = [[#"{"project_name":"PositronicKit","language":"Swift"}"#]]
        let defaults = GenerationParameters(temperature: 0.7, maxTokens: 48)
        let kit = makeKit(languageModel: llm, generationParameters: defaults)

        _ = try await kit.model.generate(ProjectMetadata.self, from: "Extract the project metadata.")

        #expect(llm.mockClient.lastParameters == defaults)
    }

    @Test("invalid schema construction fails before provider execution")
    func invalidSchemaConstruction() async throws {
        let llm = MockLLMService()
        let kit = makeKit(languageModel: llm)

        do {
            _ = try await kit.model.generate(InvalidSchemaPayload.self, from: "Do not execute")
            Issue.record("Expected schema construction to fail")
        } catch let error as StructuredGenerationError {
            guard case let .schemaConstructionFailed(typeName, reason) = error else {
                Issue.record("Expected schemaConstructionFailed, got \(error)")
                return
            }
            #expect(typeName == String(reflecting: InvalidSchemaPayload.self))
            #expect(!reason.isEmpty)
            #expect(error.errorDomain == PKErrorDomain.llm)
            #expect(error.errorCode == 1101)
            #expect(error.remediation != nil)
        } catch {
            Issue.record("Expected StructuredGenerationError, got \(error)")
        }

        #expect(llm.mockClient.streamCallCount == 0)
    }

    @Test("typed generation preserves payload decoding errors")
    func payloadDecodingErrors() async throws {
        let llm = MockLLMService()
        llm.mockClient.nextChunks = [["not json"]]
        let kit = makeKit(languageModel: llm)

        do {
            _ = try await kit.model.generate(ProjectMetadata.self, from: "Extract the project metadata.")
            Issue.record("Expected invalid JSON to fail")
        } catch let error as StructuredOutputDecodingError {
            #expect(error == .invalidJSONPayload)
        }

        llm.mockClient.nextChunks = [[#"{"project_name":42,"language":"Swift"}"#]]
        do {
            _ = try await kit.model.generate(ProjectMetadata.self, from: "Extract the project metadata.")
            Issue.record("Expected a type mismatch to fail")
        } catch let error as StructuredOutputDecodingError {
            guard case let .decodingFailed(reason) = error else {
                Issue.record("Expected decodingFailed, got \(error)")
                return
            }
            #expect(!reason.isEmpty)
        }
    }

    @Test("typed generation preserves idle timeout errors")
    func idleTimeout() async throws {
        let llm = MockLLMService()
        llm.stubbedStream = AsyncThrowingStream { _ in }
        let clock = ManualClock()
        let kit = PositronicKit(
            languageModel: llm,
            runtimeRepository: InMemoryThreadRuntimeRepository(),
            workspaceBindingRepository: InMemoryWorkspaceBindingRepository(),
            sharedRegistry: ThreadPromptJournals(),
            additionalStages: [],
            clock: clock
        )
        let request = Task {
            try await kit.model.generate(
                ProjectMetadata.self,
                from: "Extract the project metadata.",
                idleTimeout: 5
            )
        }
        defer { request.cancel() }

        try await clock.waitForSleepers()
        await clock.advance(by: .seconds(5))

        do {
            _ = try await request.value
            Issue.record("Expected the stalled typed request to time out")
        } catch let error as TurnEngineError {
            guard case let .streamTimedOut(timeout) = error else {
                Issue.record("Expected stream timeout, got \(error)")
                return
            }
            #expect(timeout == 5)
        }
    }

    @Test("typed generation preserves provider error identity")
    func providerErrorIdentity() async throws {
        let foreignError = NSError(domain: "TypedStructuredGeneration", code: 73)
        let llm = MockLLMService()
        llm.stubbedStream = AsyncThrowingStream { continuation in
            continuation.finish(throwing: foreignError)
        }
        let kit = makeKit(languageModel: llm)

        do {
            _ = try await kit.model.generate(ProjectMetadata.self, from: "Extract the project metadata.")
            Issue.record("Expected the provider error to throw")
        } catch let error as LLMStreamError {
            let underlying = error.underlyingError as NSError
            #expect(underlying.domain == foreignError.domain)
            #expect(underlying.code == foreignError.code)
        } catch {
            Issue.record("Expected LLMStreamError, got \(error)")
        }
    }

    private func makeKit(
        languageModel: MockLLMService,
        generationParameters: GenerationParameters? = nil
    ) -> PositronicKit {
        PositronicKit(configuration: .init(
            provider: .init(languageModel: languageModel),
            persistence: .init(runtimeRepository: InMemoryThreadRuntimeRepository()),
            generationParameters: generationParameters
        ))
    }
}

@Schemable
struct ProjectMetadata: Codable, Sendable, Equatable {
    let projectName: String
    let language: String

    enum CodingKeys: String, CodingKey {
        case projectName = "project_name"
        case language
    }

    init(projectName: String, language: String) {
        self.projectName = projectName
        self.language = language
    }
}

@Schemable
struct CustomDecodedPayload: Decodable, Sendable, Equatable {
    let value: String

    enum CodingKeys: String, CodingKey {
        case value = "wire_value"
    }

    init(value: String) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let value = try container.decode(String.self, forKey: .value)
        self.value = value + (decoder.userInfo[.typedStructuredGenerationSuffix] as? String ?? "")
    }
}

private extension CodingUserInfoKey {
    static let typedStructuredGenerationSuffix = CodingUserInfoKey(rawValue: "typedStructuredGenerationSuffix")!
}

private struct InvalidSchemaPayload: Decodable, Sendable, Schemable {
    typealias Schema = InvalidSchema

    static let schema = InvalidSchema()
    static let defaultAnchor = "invalid_schema_payload"
}

private struct InvalidSchema: JSONSchemaComponent {
    typealias Output = InvalidSchemaPayload

    var schemaValue: SchemaValue = .object([
        "$vocabulary": .object([
            "https://example.com/required": .boolean(true),
        ])
    ])

    func parse(_ value: JSONValue) -> Parsed<Output, ParseIssue> {
        fatalError("InvalidSchema.parse should not be called")
    }
}
