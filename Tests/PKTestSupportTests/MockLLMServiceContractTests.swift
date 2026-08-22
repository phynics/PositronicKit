import struct JSONSchema.Schema
import PKContracts
import PKTestSupport
import PositronicKit
import Testing

private struct CaptureProbeTool: Tool {
    let callName = "capture_probe"
    let name = "Capture Probe"
    let description = "Verifies that mock service requests preserve tool metadata."
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
            userQuery: "question",
            contextContributions: [contribution],
            chatHistory: [history],
            tools: [tool],
            workspaces: [workspace],
            primaryWorkspace: workspace,
            requestOriginName: "tests",
            systemInstructions: "system",
            structuredOutput: .jsonObject,
            generationParameters: parameters,
            modelTier: .fast
        )

        let result = try await service.generationStreamWithContext(request)
        _ = try await result.stream.collect()

        let captured = service.lastGenerationRequest
        #expect(captured?.userQuery == "question")
        #expect(captured?.contextContributions.map(\.noteName) == ["host.context"])
        #expect(captured?.chatHistory.map(\.id) == [history.id])
        #expect(captured?.tools.map(\.identity) == [tool.identity])
        #expect(captured?.tools.map(\.callName) == ["capture_probe"])
        #expect(captured?.tools.map(\.name) == ["Capture Probe"])
        #expect(captured?.tools.map(\.description) == ["Verifies that mock service requests preserve tool metadata."])
        #expect(captured?.tools.map(\.origin) == [.named("contract-test")])
        #expect(captured?.workspaces.map(\.id) == [workspace.id])
        #expect(captured?.primaryWorkspace?.id == workspace.id)
        #expect(captured?.requestOriginName == "tests")
        #expect(captured?.systemInstructions == "system")
        #expect(captured?.structuredOutput == .jsonObject)
        #expect(captured?.generationParameters == parameters)
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

    @Test("send calls preserve complete capture records")
    func sendCallsPreserveCompleteCaptureRecords() async throws {
        let service = MockLLMService()
        service.nextResponse = "ok"
        let parameters = GenerationParameters(maxTokens: 12)

        _ = try await service.sendMessage("simple")
        _ = try await service.sendMessage(
            "configured",
            responseFormat: .jsonObject,
            generationParameters: parameters,
            modelTier: .utility
        )

        #expect(service.sendMessageCaptureHistory.count == 2)
        #expect(service.lastSendMessageCapture?.content == "configured")
        #expect(service.lastSendMessageCapture?.responseFormat == .jsonObject)
        #expect(service.lastSendMessageCapture?.generationParameters == parameters)
        #expect(service.lastSendMessageCapture?.modelTier == .utility)
    }

    @Test("concurrent title generation loses no captures")
    func concurrentTitleGenerationLosesNoCaptures() async throws {
        let service = MockLLMService()
        let expected = Set((0 ..< 100).map { "title-input-\($0)" })

        try await withThrowingTaskGroup(of: Void.self) { group in
            for content in expected {
                group.addTask {
                    _ = await service.bestEffortTitle(for: [.fixture(content: content)])
                }
            }
            try await group.waitForAll()
        }

        let actual = service.generatedTitleInputs.compactMap { $0.first?.content }
        #expect(actual.count == expected.count)
        #expect(Set(actual) == expected)
    }
}
