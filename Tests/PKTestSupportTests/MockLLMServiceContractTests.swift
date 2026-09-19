import struct JSONSchema.Schema
import PKContracts
import PKTestSupport
import PositronicKit
import Testing

private struct CaptureProbeTool: PKTool {
    let callName = "capture_probe"
    let name = "Capture Probe"
    let toolDescription = "Verifies that mock service requests preserve tool metadata."
    let requiresPermission = false

    var parametersSchema: Schema {
        ToolParameterSchema.object {}.schemaDefinition
    }

    func canExecute() async -> Bool { true }

    func execute(parameters _: [String: AnyCodable]) async throws -> ToolResult {
        .success("captured")
    }
}

@Suite("MockLLMService contracts")
struct MockLLMServiceContractTests {
    @Test("configuration update, clear, export, and import form a truthful lifecycle")
    func configurationLifecycleRoundTrips() async throws {
        let service = MockLLMService()
        let configuration = LLMConfiguration.fixture(
            modelName: "round-trip-model",
            activeProvider: .ollama,
            memoryContextLimit: 11,
            documentContextLimit: 13
        )

        try await service.updateConfiguration(configuration)
        #expect(await service.isConfigured)
        #expect(await service.configuration == configuration)

        let exported = try await service.exportConfiguration()
        await service.clearConfiguration()
        #expect(await !service.isConfigured)
        #expect(await service.configuration == .openAI)

        try await service.importConfiguration(from: exported)
        #expect(await service.isConfigured)
        #expect(await service.configuration == configuration)
    }

    @Test("context request and actual model tier are captured completely")
    func contextRequestAndActualModelTierAreCapturedCompletely() async throws {
        let service = MockLLMService()
        service.mockClient.nextResponse = "ok"
        let contribution = try TurnContextContribution(namespace: "host", key: "context", text: "context")
        let history = Message.fixture(content: "earlier")
        let workspace = WorkspaceReference.fixture(rootPath: "/tmp/workspace")
        let parameters = GenerationParameters(topP: 0.8, seed: 99)
        let tool = AnyTool(CaptureProbeTool(), origin: .named("contract-test"))
        let request = LLMGenerationRequest(
            prompt: LLMPromptRequest(
                userQuery: "question",
                contextContributions: [contribution],
                chatHistory: [history],
                tools: [tool],
                workspaces: [workspace],
                primaryWorkspace: workspace,
                requestOriginName: "tests",
                systemInstructions: "system",
                generationParameters: parameters
            ),
            structuredOutput: .jsonObject,
            modelTier: .fast
        )

        let result = try await service.generationStreamWithContext(request)
        _ = try await result.stream.collect()

        let captured = service.lastGenerationRequest
        #expect(captured?.prompt.userQuery == "question")
        #expect(captured?.prompt.contextContributions.map(\.noteName) == ["host.context"])
        #expect(captured?.prompt.chatHistory.map(\.id) == [history.id])
        #expect(captured?.prompt.tools.map(\.identity) == [tool.identity])
        #expect(captured?.prompt.tools.map(\.callName) == ["capture_probe"])
        #expect(captured?.prompt.tools.map(\.name) == ["Capture Probe"])
        #expect(captured?.prompt.tools.map(\.toolDescription) == ["Verifies that mock service requests preserve tool metadata."])
        #expect(captured?.prompt.tools.map(\.origin) == [.named("contract-test")])
        #expect(captured?.prompt.workspaces.map(\.id) == [workspace.id])
        #expect(captured?.prompt.primaryWorkspace?.id == workspace.id)
        #expect(captured?.prompt.requestOriginName == "tests")
        #expect(captured?.prompt.systemInstructions == "system")
        #expect(captured?.structuredOutput == .jsonObject)
        #expect(captured?.prompt.generationParameters == parameters)
        #expect(captured?.modelTier == .fast)
        #expect(service.generationRequestHistory.count == 1)
        #expect(service.lastModelTier == .fast)
        #expect(service.modelTierHistory == [.fast])
    }

    @Test("stubbed and throwing streams are still captured")
    func stubbedAndThrowingStreamsAreStillCaptured() async throws {
        let service = MockLLMService()
        enum StubError: Error { case failed }
        service.stubbedStream = AsyncThrowingStream { continuation in
            continuation.finish(throwing: StubError.failed)
        }
        let parameters = GenerationParameters(temperature: 0.4)

        let stream = await service.generationStream(
            messages: [LLMMessage(role: .user, content: "stubbed")],
            tools: [LLMToolDefinition(name: "echo")],
            toolChoice: .auto,
            responseFormat: .text,
            generationParameters: parameters,
            modelTier: .utility
        )
        do {
            _ = try await stream.collect()
            Issue.record("Expected the stubbed stream error")
        } catch {}

        #expect(service.lastGenerationCapture?.messages.first?.content == "stubbed")
        #expect(service.lastGenerationCapture?.tools?.map(\.name) == ["echo"])
        #expect(service.lastGenerationCapture?.toolChoice == .auto)
        #expect(service.lastGenerationCapture?.responseFormat == .text)
        #expect(service.lastGenerationCapture?.generationParameters == parameters)
        #expect(service.lastGenerationCapture?.modelTier == .utility)
        #expect(service.generationCaptureHistory.count == 1)
    }

}
