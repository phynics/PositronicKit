import Foundation
import Testing
@testable import PositronicKit
@testable import PKShared
import PKTestSupport

struct GenerationParametersTests {
    @Test
    func testDefaultGenerationParametersInPositronicKitCore() async throws {
        let mockLLM = MockLLMService()
        let mockPersistence = MockPersistenceService()
        let timelineId = UUID()
        
        // 1. Setup PositronicKitCore with default generation parameters
        let defaultParams = GenerationParameters(temperature: 0.7, maxTokens: 100)
        let chat = PositronicKitCore(
            llmService: mockLLM,
            persistence: .init(
                messageStore: mockPersistence,
                timelinePersistence: mockPersistence,
                workspacePersistence: mockPersistence,
                memoryStore: mockPersistence,
                toolPersistence: mockPersistence,
                agentInstanceStore: mockPersistence,
                clientStore: mockPersistence,
                agentTemplateStore: mockPersistence
            ),
            generationParameters: defaultParams
        )
        
        // 2. Run a chat turn without per-run parameters
        let stream = try await chat.run(
            timelineId: timelineId,
            message: "Test message"
        )
        
        // Drain stream
        for try await _ in stream {}
        
        // 3. Verify parameters reached the LLM client
        let lastParams = await mockLLM.mockClient.lastParameters
        #expect(lastParams?.temperature == 0.7)
        #expect(lastParams?.maxTokens == 100)
    }
    
    @Test
    func testOverrideGenerationParametersInRun() async throws {
        let mockLLM = MockLLMService()
        let mockPersistence = MockPersistenceService()
        let timelineId = UUID()
        
        // 1. Setup PositronicKitCore with initial default parameters
        let defaultParams = GenerationParameters(temperature: 0.7, maxTokens: 100)
        let chat = PositronicKitCore(
            llmService: mockLLM,
            persistence: .init(
                messageStore: mockPersistence,
                timelinePersistence: mockPersistence,
                workspacePersistence: mockPersistence,
                memoryStore: mockPersistence,
                toolPersistence: mockPersistence,
                agentInstanceStore: mockPersistence,
                clientStore: mockPersistence,
                agentTemplateStore: mockPersistence
            ),
            generationParameters: defaultParams
        )
        
        // 2. Run a chat turn WITH per-run parameters that override the defaults
        let overrideParams = GenerationParameters(temperature: 0.2, maxTokens: 500, topP: 0.9)
        let stream = try await chat.run(
            timelineId: timelineId,
            message: "Test message",
            generationParameters: overrideParams
        )
        
        // Drain stream
        for try await _ in stream {}
        
        // 3. Verify override parameters reached the LLM client
        let lastParams = await mockLLM.mockClient.lastParameters
        #expect(lastParams?.temperature == 0.2)
        #expect(lastParams?.maxTokens == 500)
        #expect(lastParams?.topP == 0.9)
    }
    
    @Test
    func testNilParametersPropagation() async throws {
        let mockLLM = MockLLMService()
        let mockPersistence = MockPersistenceService()
        let timelineId = UUID()
        
        // 1. Setup PositronicKitCore without any default parameters
        let chat = PositronicKitCore(llmService: mockLLM)
        
        // 2. Run a chat turn without per-run parameters
        let stream = try await chat.run(
            timelineId: timelineId,
            message: "Test message"
        )
        
        // Drain stream
        for try await _ in stream {}
        
        // 3. Verify nil parameters reached the LLM client (meaning it will fall back to LLM config)
        let lastParams = await mockLLM.mockClient.lastParameters
        #expect(lastParams == nil)
    }
}
