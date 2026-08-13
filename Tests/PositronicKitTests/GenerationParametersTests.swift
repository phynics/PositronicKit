import Foundation
import Testing
@testable import PositronicKit
@testable import PKShared
import PKUtilities
import PKTestSupport

struct GenerationParametersTests {
    @Test
    func testDefaultGenerationParametersInPositronicKit() async throws {
        let mockLLM = MockLLMService()
        let mockPersistence = MockPersistenceService()

        // 1. Setup PositronicKit with default generation parameters
        let defaultParams = GenerationParameters(temperature: 0.7, maxTokens: 100)
        let chat = PositronicKit(configuration: .init(provider: .init(languageModel: mockLLM), persistence: .init(
                messageStore: mockPersistence,
                threadPersistence: mockPersistence,
                workspacePersistence: mockPersistence,
                memoryStore: mockPersistence,
                toolPersistence: mockPersistence,
                agentInstanceStore: mockPersistence,
                requestOriginStore: mockPersistence
            ), generationParameters: defaultParams))

        let thread = try await chat.threadManager.createThread(title: "Default Params")

        // 2. Run a chat turn without per-run parameters
        let stream = try await chat.run(ChatRunRequest(
            threadID: thread.id,
            message: "Test message"
        ))

        // Drain stream
        for try await _ in stream {}

        // 3. Verify parameters reached the mock LLM transport
        let lastParams = mockLLM.mockClient.lastParameters
        #expect(lastParams?.temperature == 0.7)
        #expect(lastParams?.maxTokens == 100)
    }

    @Test
    func testOverrideGenerationParametersInRun() async throws {
        let mockLLM = MockLLMService()
        let mockPersistence = MockPersistenceService()

        // 1. Setup PositronicKit with initial default parameters
        let defaultParams = GenerationParameters(temperature: 0.7, maxTokens: 100)
        let chat = PositronicKit(configuration: .init(provider: .init(languageModel: mockLLM), persistence: .init(
                messageStore: mockPersistence,
                threadPersistence: mockPersistence,
                workspacePersistence: mockPersistence,
                memoryStore: mockPersistence,
                toolPersistence: mockPersistence,
                agentInstanceStore: mockPersistence,
                requestOriginStore: mockPersistence
            ), generationParameters: defaultParams))

        let thread = try await chat.threadManager.createThread(title: "Override Params")

        // 2. Run a chat turn WITH per-run parameters that override the defaults
        let overrideParams = GenerationParameters(temperature: 0.2, maxTokens: 500, topP: 0.9)
        let stream = try await chat.run(ChatRunRequest(
            threadID: thread.id,
            message: "Test message",
            generationParameters: overrideParams
        ))

        // Drain stream
        for try await _ in stream {}

        // 3. Verify override parameters reached the mock LLM transport
        let lastParams = mockLLM.mockClient.lastParameters
        #expect(lastParams?.temperature == 0.2)
        #expect(lastParams?.maxTokens == 500)
        #expect(lastParams?.topP == 0.9)
    }

    @Test
    func testNilParametersPropagation() async throws {
        let mockLLM = MockLLMService()

        // 1. Setup PositronicKit without any default parameters
        let chat = PositronicKit(languageModel: mockLLM)

        let thread = try await chat.threadManager.createThread(title: "Nil Params")

        // 2. Run a chat turn without per-run parameters
        let stream = try await chat.run(ChatRunRequest(
            threadID: thread.id,
            message: "Test message"
        ))

        // Drain stream
        for try await _ in stream {}

        // 3. Verify nil parameters reached the mock LLM transport (meaning it will fall back to LLM config)
        let lastParams = mockLLM.mockClient.lastParameters
        #expect(lastParams == nil)
    }
}
