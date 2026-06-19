import Foundation
import Testing
import PKTestSupport
@testable import PositronicKit
@testable import PKShared

@Suite("Unconfigured LLM Service")
struct UnconfiguredLLMServiceTests {
    let service = UnconfiguredLLMService()

    private var request: LLMChatRequest {
        LLMChatRequest(
            userQuery: "hello",
            chatHistory: [],
            tools: [],
            workspaces: [],
            primaryWorkspace: nil,
            requestOriginName: nil
        )
    }

    @Test("Throwing configuration methods return notConfigured")
    func throwingConfigurationMethodsReturnNotConfigured() async throws {
        let config = LLMConfiguration(endpoint: "https://example.com", modelName: "model", apiKey: "key")

        await #expect(throws: LLMServiceError.notConfigured) {
            try await service.updateConfiguration(config)
        }
        await #expect(throws: LLMServiceError.notConfigured) {
            try await service.restoreFromBackup()
        }
        await #expect(throws: LLMServiceError.notConfigured) {
            _ = try await service.exportConfiguration()
        }
        await #expect(throws: LLMServiceError.notConfigured) {
            try await service.importConfiguration(from: Data())
        }
    }

    @Test("Message and model methods return notConfigured")
    func messageAndModelMethodsReturnNotConfigured() async throws {
        await #expect(throws: LLMServiceError.notConfigured) {
            _ = try await service.sendMessage("hello")
        }
        await #expect(throws: LLMServiceError.notConfigured) {
            _ = try await service.sendMessage(
                "hello",
                responseFormat: .jsonObject,
                generationParameters: nil,
                useUtilityModel: true
            )
        }
        await #expect(throws: LLMServiceError.notConfigured) {
            _ = try await service.fetchAvailableModels()
        }
    }

    @Test("chatStream terminates immediately with notConfigured")
    func chatStreamTerminatesImmediately() async throws {
        let stream = await service.chatStream(
            messages: [],
            tools: nil,
            toolChoice: nil,
            responseFormat: nil,
            generationParameters: nil,
            useUtilityModel: false,
            useFastModel: false
        )

        await #expect(throws: LLMServiceError.notConfigured) {
            _ = try await stream.collect()
        }
    }

    @Test("chatStreamWithContext terminates immediately with notConfigured")
    func chatStreamWithContextTerminatesImmediately() async throws {
        await #expect(throws: LLMServiceError.notConfigured) {
            let result = try await service.chatStreamWithContext(request)
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
