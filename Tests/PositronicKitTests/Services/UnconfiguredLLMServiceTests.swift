import Foundation
@testable import PKContracts
import PKTestSupport
import PKUtilities
@testable import PositronicKit
import Testing

@Suite("Unconfigured LLM Service")
struct UnconfiguredLLMServiceTests {
    let service = UnconfiguredLLMService()

    private var request: LLMGenerationRequest {
        LLMGenerationRequest(
            userQuery: "hello",
            chatHistory: [],
            tools: [],
            workspaces: [],
            primaryWorkspace: nil,
            requestOriginName: nil
        )
    }

    @Test("generationStream terminates immediately with notConfigured")
    func generationStreamTerminatesImmediately() async throws {
        let stream = await service.generationStream(
            messages: [],
            tools: nil,
            toolChoice: nil,
            responseFormat: nil,
            generationParameters: nil,
            modelTier: .primary
        )

        await #expect(throws: LLMServiceError.notConfigured) {
            _ = try await stream.collect()
        }
    }

    @Test("generationStreamWithContext terminates immediately with notConfigured")
    func generationStreamWithContextTerminatesImmediately() async throws {
        await #expect(throws: LLMServiceError.notConfigured) {
            let result = try await service.generationStreamWithContext(request)
            _ = try await result.stream.collect()
        }
    }

    @Test("empty object schema construction does not crash and remains object-shaped")
    func emptyObjectSchemaIsAlwaysConstructible() throws {
        let schema = makeEmptyObjectSchema()
        let data = try JSONEncoder().encode(schema)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["type"] as? String == "object")
        #expect(object["properties"] as? [String: Any] != nil)
    }
}
