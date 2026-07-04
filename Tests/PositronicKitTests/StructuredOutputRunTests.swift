import Foundation
import JSONSchemaBuilder
@testable import PKShared
import PKTestSupport
@testable import PositronicKit
import Testing

@Suite("Structured Output Run")
@MainActor
struct StructuredOutputRunTests {
    @Test("run forwards structured output requests to the LLM transport")
    func runForwardsStructuredOutputRequests() async throws {
        let mockLLM = MockLLMService()
        let mockPersistence = MockPersistenceService()
        let chat = PositronicKit(
            llmService: mockLLM,
            persistence: .init(
                messageStore: mockPersistence,
                timelinePersistence: mockPersistence,
                workspacePersistence: mockPersistence,
                memoryStore: mockPersistence,
                toolPersistence: mockPersistence,
                agentInstanceStore: mockPersistence,
                requestOriginStore: mockPersistence
            )
        )

        let stream = try await chat.run(
            timelineId: UUID(),
            message: "Extract tags",
            structuredOutput: .jsonSchema(StructuredOutputFixtures.tagSchemaDefinition())
        )

        for try await _ in stream {}

        guard case let .jsonSchema(schema) = mockLLM.mockClient.lastResponseFormat else {
            Issue.record("Expected run() to forward a JSON schema response format")
            return
        }

        #expect(schema.name == "tag_payload")
        let encodedSchema = String(decoding: try JSONEncoder().encode(schema.schema), as: UTF8.self)
        #expect(encodedSchema.contains("\"tags\""))
    }

    @Test("run has a single overload, so omitting structuredOutput cannot silently select a nil-hardcoding overload")
    func runOmittingStructuredOutputUsesTheSameSingleOverload() async throws {
        let mockLLM = MockLLMService()
        let mockPersistence = MockPersistenceService()
        let chat = PositronicKit(
            llmService: mockLLM,
            persistence: .init(
                messageStore: mockPersistence,
                timelinePersistence: mockPersistence,
                workspacePersistence: mockPersistence,
                memoryStore: mockPersistence,
                toolPersistence: mockPersistence,
                agentInstanceStore: mockPersistence,
                requestOriginStore: mockPersistence
            )
        )

        // Regression guard for YAK-12: PositronicKit previously had a convenience `run(...)`
        // overload without `structuredOutput` that delegated to the full overload with
        // `structuredOutput: nil`. Because both overloads were callable with the same argument
        // list, omitting the parameter silently resolved to the nil-hardcoding overload. There
        // is now exactly one `run(...)`, with `structuredOutput` defaulting to nil, so omission
        // is unambiguous rather than a footgun.
        let stream = try await chat.run(
            timelineId: UUID(),
            message: "Hello"
        )

        for try await _ in stream {}

        #expect(mockLLM.mockClient.lastResponseFormat == nil)
    }

    @Test("sidecarsIfEnabled preserves the exact no-sidecar runtime path when disabled")
    func sidecarsIfEnabledDisablesSidecarsWithoutChangingRunBehavior() async throws {
        let directives = [
            SidecarDirective(
                name: "title",
                instruction: "Short title.",
                schema: JSONString().definition()
            ),
        ]

        #expect(PositronicKit.sidecarsIfEnabled(directives, when: false).isEmpty)
        #expect(PositronicKit.sidecarsIfEnabled(directives, when: true) == directives)

        let mockLLM = MockLLMService()
        let mockPersistence = MockPersistenceService()
        let chat = PositronicKit(
            llmService: mockLLM,
            persistence: .init(
                messageStore: mockPersistence,
                timelinePersistence: mockPersistence,
                workspacePersistence: mockPersistence,
                memoryStore: mockPersistence,
                toolPersistence: mockPersistence,
                agentInstanceStore: mockPersistence,
                requestOriginStore: mockPersistence
            )
        )

        let stream = try await chat.run(
            timelineId: UUID(),
            message: "Hello",
            sidecars: PositronicKit.sidecarsIfEnabled(directives, when: false)
        )

        for try await _ in stream {}

        #expect(mockLLM.mockClient.lastResponseFormat == nil)
    }
}
