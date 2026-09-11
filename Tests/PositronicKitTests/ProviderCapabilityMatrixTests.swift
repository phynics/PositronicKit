import Foundation
import OpenAI
import PKContracts
import PKTestSupport
@testable import PKAnthropicProvider
@testable import PKFoundationModelsProvider
@testable import PKOllamaProvider
@testable import PKOpenAIProvider
@testable import PKOpenRouterProvider
@testable import PositronicKit
import Logging
import Synchronization
import Testing

private let registeredCaseIDs: Set<String> = [
    "openai.image-input.ordered-content-parts",
    "openai.audio-input.wav",
    "openai.audio-input.mp3",
    "openai.audio-output.streamed-transcript",
    "openai.audio-input.flac-rejected",
    "openrouter.image-input.ordered-content-parts",
    "openrouter.audio-input.wav",
    "openrouter.audio-input.mp3",
    "openrouter.audio-output.streamed-transcript",
    "anthropic.image-input.ordered-base64-blocks",
    "anthropic.audio-input.rejected",
    "anthropic.audio-output.rejected",
    "ollama.image-input.base64-array",
    "ollama.mixed-layout.rejected",
    "ollama.audio-input.rejected",
    "ollama.audio-output.rejected",
    "foundation-models.image-input.disabled",
    "foundation-models.audio-input.disabled",
    "runtime.openai.invalid-audio-order",
    "runtime.openrouter.invalid-audio-order",
    "runtime.anthropic.audio-rejected",
    "runtime.ollama.mixed-layout",
]

@Suite("Provider capability matrix", .serialized)
struct ProviderCapabilityMatrixTests {
    @Test("every manifest row has an executable assertion")
    func everyManifestRowRuns() async throws {
        let manifest = try ProviderCapabilityMatrixManifest.load()
        let manifestIDs = Set(manifest.cases.map(\.id))
        #expect(manifestIDs == registeredCaseIDs)

        for matrixCase in manifest.cases {
            try await run(matrixCase)
        }
    }

    private func run(_ matrixCase: ProviderCapabilityMatrixManifest.Case) async throws {
        switch matrixCase.id {
        case "openai.image-input.ordered-content-parts":
            try assertOpenAIOrderedParts(matrixCase.id)
        case "openai.audio-input.wav":
            try assertOpenAIAudioInput(matrixCase.id, format: .wav)
        case "openai.audio-input.mp3":
            try assertOpenAIAudioInput(matrixCase.id, format: .mp3)
        case "openai.audio-output.streamed-transcript":
            try assertOpenAIAudioOutput(matrixCase.id)
        case "openai.audio-input.flac-rejected":
            assertOpenAIAudioRejected(matrixCase.id)
        case "openrouter.image-input.ordered-content-parts":
            try assertOpenRouterOrderedParts(matrixCase.id)
        case "openrouter.audio-input.wav":
            try assertOpenRouterAudioInput(matrixCase.id, format: .wav)
        case "openrouter.audio-input.mp3":
            try assertOpenRouterAudioInput(matrixCase.id, format: .mp3)
        case "openrouter.audio-output.streamed-transcript":
            try assertOpenRouterAudioOutput(matrixCase.id)
        case "anthropic.image-input.ordered-base64-blocks":
            try assertAnthropicImageBlocks(matrixCase.id)
        case "anthropic.audio-input.rejected":
            assertAnthropicAudioRejected(matrixCase.id)
        case "anthropic.audio-output.rejected":
            try await assertRuntimeAudioOutputOrdering(matrixCase.id, provider: .anthropic, capabilities: [.audioOutput], expected: .missingCapability(.audioOutput))
        case "ollama.image-input.base64-array":
            try assertOllamaImageArray(matrixCase.id)
        case "ollama.mixed-layout.rejected":
            assertOllamaMixedLayoutRejected(matrixCase.id)
        case "ollama.audio-input.rejected":
            assertOllamaAudioRejected(matrixCase.id)
        case "ollama.audio-output.rejected":
            try await assertRuntimeAudioOutputOrdering(matrixCase.id, provider: .ollama, capabilities: [.audioOutput], expected: .missingCapability(.audioOutput))
        case "foundation-models.image-input.disabled":
            try await assertFoundationModelsDisabled(
                matrixCase.id,
                part: .image(.init(data: Data([1]), mediaType: "image/png")),
                expected: .missingCapability(.imageInput)
            )
        case "foundation-models.audio-input.disabled":
            try await assertFoundationModelsDisabled(
                matrixCase.id,
                part: .audio(.init(data: Data([1]), format: .wav)),
                expected: .missingCapability(.audioInput)
            )
        case "runtime.openai.invalid-audio-order":
            try await assertRuntimeOrdering(matrixCase.id, provider: .openAI, capabilities: [.audioInput], content: .init(parts: [.audio(.init(data: Data([1]), format: .flac))]), expected: .unsupportedAudioFormat(.flac, provider: .openAI))
        case "runtime.openrouter.invalid-audio-order":
            try await assertRuntimeOrdering(matrixCase.id, provider: .openRouter, capabilities: [.audioInput], content: .init(parts: [.audio(.init(data: Data([1]), format: .flac))]), expected: .unsupportedAudioFormat(.flac, provider: .openRouter))
        case "runtime.anthropic.audio-rejected":
            try await assertRuntimeOrdering(matrixCase.id, provider: .anthropic, capabilities: [.audioInput], content: .init(parts: [.audio(.init(data: Data([1]), format: .wav))]), expected: .missingCapability(.audioInput))
        case "runtime.ollama.mixed-layout":
            try await assertRuntimeOrdering(matrixCase.id, provider: .ollama, capabilities: [.imageInput], content: .init(parts: [.text("before"), .image(.init(data: Data([1]), mediaType: "image/png"))]), expected: .unsupportedContentLayout(provider: .ollama))
        default:
            Issue.record("unregistered provider capability scenario: \(matrixCase.id)")
        }
    }

    private func assertOpenAIOrderedParts(_ id: String) throws {
        let message = LLMMessage(role: .user, content: .init(parts: [
            .text("before"),
            .image(.init(data: Data([1]), mediaType: "image/png")),
            .text("after"),
        ]))
        let encoded = try JSONEncoder().encode(try message.toOpenAIMessageParam())
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let content = try #require(object["content"] as? [[String: Any]])
        #expect(content.compactMap { $0["type"] as? String } == ["text", "image_url", "text"], "\(id)")
        #expect(
            ((content[1]["image_url"] as? [String: Any])?["url"] as? String)
                == "data:image/png;base64,AQ==",
            "\(id)"
        )
        #expect((content[1]["image_url"] as? [String: Any])?["url"] as? String == "data:image/png;base64,AQ==", "\(id)")
    }

    private func assertOpenAIAudioInput(_ id: String, format: AudioFormat) throws {
        let message = LLMMessage(role: .user, content: .init(parts: [
            .text("before"), .audio(.init(data: Data([1]), format: format)), .text("after"),
        ]))
        let encoded = try JSONEncoder().encode(try message.toOpenAIMessageParam())
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let content = try #require(object["content"] as? [[String: Any]])
        #expect(content.compactMap { $0["type"] as? String } == ["text", "input_audio", "text"], "\(id)")
        #expect((content[1]["input_audio"] as? [String: Any])?["format"] as? String == format.rawValue, "\(id)")
    }

    private func assertOpenAIAudioOutput(_ id: String) throws {
        let data = Data(#"{"id":"audio-1","object":"chat.completion.chunk","created":0,"model":"gpt-4o","choices":[{"index":0,"delta":{"audio":{"id":"audio-1","data":"AQ==","transcript":"hello","expires_at":4102444800}},"finish_reason":"stop"}]}"#.utf8)
        let chunk = try JSONDecoder().decode(ChatStreamResult.self, from: data).toLLMStreamChunk(audioFormat: .wav)
        let delta = try #require(chunk.choices.first?.delta.audio)
        #expect(delta.data == Data([1]), "\(id)")
        #expect(delta.transcript == "hello", "\(id)")
        #expect(chunk.choices.first?.finishReason == "stop", "\(id)")
    }

    private func assertOpenAIAudioRejected(_ id: String) {
        let message = LLMMessage(role: .user, content: .init(parts: [.audio(.init(data: Data([1]), format: .flac))]))
        do {
            _ = try message.toOpenAIMessageParam()
            Issue.record("\(id): expected unsupportedAudioFormat")
        } catch let error as MultimodalContentError {
            #expect(error == .unsupportedAudioFormat(.flac, provider: .openAI), "\(id)")
        } catch {
            Issue.record("\(id): unexpected error \(error)")
        }
    }

    private func assertOpenRouterOrderedParts(_ id: String) throws {
        let message = LLMMessage(role: .user, content: .init(parts: [
            .text("before"), .image(.init(data: Data([1]), mediaType: "image/png")), .text("after"),
        ]))
        let encoded = try JSONEncoder().encode(OpenRouterMessage(message))
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let content = try #require(object["content"] as? [[String: Any]])
        #expect(content.compactMap { $0["type"] as? String } == ["text", "image_url", "text"], "\(id)")
    }

    private func assertOpenRouterAudioInput(_ id: String, format: AudioFormat) throws {
        let message = LLMMessage(role: .user, content: .init(parts: [
            .text("before"), .audio(.init(data: Data([1]), format: format)), .text("after"),
        ]))
        let encoded = try JSONEncoder().encode(OpenRouterMessage(message))
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let content = try #require(object["content"] as? [[String: Any]])
        #expect(content.compactMap { $0["type"] as? String } == ["text", "input_audio", "text"], "\(id)")
        #expect((content[1]["input_audio"] as? [String: Any])?["format"] as? String == format.rawValue, "\(id)")
    }

    private func assertOpenRouterAudioOutput(_ id: String) throws {
        let data = Data(#"{"id":"audio-1","model":"route","choices":[{"index":0,"delta":{"audio":{"data":"AQ==","transcript":"hello","id":"audio-1","expires_at":4102444800}},"finish_reason":"stop"}]}"#.utf8)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let chunk = try decoder.decode(OpenRouterStreamChunk.self, from: data).toLLMStreamChunk(audioFormat: .mp3)
        let delta = try #require(chunk.choices.first?.delta.audio)
        #expect(delta.data == Data([1]), "\(id)")
        #expect(delta.transcript == "hello", "\(id)")
        #expect(delta.format == .mp3, "\(id)")
    }

    private func assertAnthropicImageBlocks(_ id: String) throws {
        let (_, messages) = try AnthropicMessageConversion.convert(
            messages: [LLMMessage(role: .user, content: .init(parts: [
                .text("before"), .image(.init(data: Data([1]), mediaType: "image/png")), .text("after"),
            ]))],
            logger: Logger(label: "provider-capability-matrix")
        )
        let encoded = try JSONEncoder().encode(messages)
        let array = try #require(JSONSerialization.jsonObject(with: encoded) as? [[String: Any]])
        let blocks = try #require(array.first?["content"] as? [[String: Any]])
        #expect(blocks.compactMap { $0["type"] as? String } == ["text", "image", "text"], "\(id)")
        #expect((blocks[1]["source"] as? [String: Any])?["data"] as? String == "AQ==", "\(id)")
    }

    private func assertAnthropicAudioRejected(_ id: String) {
        let message = LLMMessage(role: .user, content: .init(parts: [.audio(.init(data: Data([1]), format: .wav))]))
        do {
            _ = try AnthropicMessageConversion.convert(messages: [message], logger: Logger(label: "provider-capability-matrix"))
            Issue.record("\(id): expected audio rejection")
        } catch let error as MultimodalContentError {
            #expect(error == .missingCapability(.audioInput), "\(id)")
        } catch {
            Issue.record("\(id): unexpected error \(error)")
        }
    }

    private func assertOllamaImageArray(_ id: String) throws {
        let message = try OllamaMessage(validating: LLMMessage(role: .user, content: .init(parts: [
            .image(.init(data: Data([1]), mediaType: "image/png")),
            .image(.init(data: Data([2]), mediaType: "image/jpeg")),
        ])))
        #expect(message.images == ["AQ==", "Ag=="], "\(id)")
    }

    private func assertOllamaMixedLayoutRejected(_ id: String) {
        let message = LLMMessage(role: .user, content: .init(parts: [.text("before"), .image(.init(data: Data([1]), mediaType: "image/png"))]))
        expectOllamaError(id, message: message, expected: .unsupportedContentLayout(provider: .ollama))
    }

    private func assertOllamaAudioRejected(_ id: String) {
        let message = LLMMessage(role: .user, content: .init(parts: [.audio(.init(data: Data([1]), format: .wav))]))
        expectOllamaError(id, message: message, expected: .missingCapability(.audioInput))
    }

    private func expectOllamaError(_ id: String, message: LLMMessage, expected: MultimodalContentError) {
        do {
            _ = try OllamaMessage(validating: message)
            Issue.record("\(id): expected \(expected)")
        } catch let error as MultimodalContentError {
            #expect(error == expected, "\(id)")
        } catch {
            Issue.record("\(id): unexpected error \(error)")
        }
    }

    private func assertFoundationModelsDisabled(
        _ id: String,
        part: MessageContentPart,
        expected: MultimodalContentError
    ) async throws {
        let factoryCalls = Mutex(0)
        let client = FoundationModelsClient(makeSession: { _, _ in
            factoryCalls.withLock { $0 += 1 }
            return MatrixFoundationModelsSession()
        })
        let stream = await client.chatStream(
            messages: [LLMMessage(role: .user, content: .init(parts: [part]))],
            tools: nil,
            toolChoice: nil,
            responseFormat: nil,
            generationParameters: nil
        )
        do {
            for try await _ in stream {}
            Issue.record("\(id): expected media capability rejection")
        } catch let error as MultimodalContentError {
            #expect(error == expected, "\(id)")
        } catch {
            Issue.record("\(id): unexpected error \(error)")
        }
        #expect(factoryCalls.withLock { $0 } == 0, "\(id): session factory must not be invoked")
    }

    private func assertRuntimeOrdering(
        _ id: String,
        provider: LLMProvider,
        capabilities: Set<ModelCapability>,
        content: MessageContent,
        expected: MultimodalContentError
    ) async throws {
        let llm = MockLLMService()
        var configuration = LLMConfiguration(activeProvider: provider)
        var providerConfiguration = configuration.activeProviderConfiguration
        providerConfiguration.capabilities = capabilities
        configuration.activeProviderConfiguration = providerConfiguration
        llm.mockConfig = configuration

        let persistence = MockPersistenceService()
        let kit = PositronicKit(configuration: .init(
            provider: .init(languageModel: llm),
            persistence: .init(
                runtimeRepository: persistence,
                workspacePersistence: persistence,
                toolPersistence: persistence,
                agentStore: persistence,
                requestOriginStore: persistence
            )
        ))
        let threadID = UUID()
        let request = TurnRequest(threadID: threadID, content: content)

        do {
            _ = try await kit.startTurnHandle(request, agentID: nil, executionKind: .direct)
            Issue.record("\(id): expected runtime ordering rejection")
        } catch let error as MultimodalContentError {
            #expect(error == expected, "\(id)")
        } catch {
            Issue.record("\(id): unexpected error \(error)")
        }

        #expect(persistence.persistenceAccessCount == 0, "\(id): persistence was accessed")
        #expect(llm.generationRequestHistory.isEmpty, "\(id): provider generation request occurred")
        #expect(llm.mockClient.generationCaptureHistory.isEmpty, "\(id): low-level provider request occurred")
        #expect(persistence.messages.isEmpty, "\(id): user message was persisted")
        #expect(persistence.threads.isEmpty, "\(id): thread admission was persisted")
        #expect(await kit.turnEngine.dependencies.promptHistoryRegistry.containsHistory(for: threadID) == false, "\(id): prompt history was created")
    }

    private func assertRuntimeAudioOutputOrdering(
        _ id: String,
        provider: LLMProvider,
        capabilities: Set<ModelCapability>,
        expected: MultimodalContentError
    ) async throws {
        let llm = MockLLMService()
        var configuration = LLMConfiguration(activeProvider: provider)
        var providerConfiguration = configuration.activeProviderConfiguration
        providerConfiguration.capabilities = capabilities
        configuration.activeProviderConfiguration = providerConfiguration
        llm.mockConfig = configuration

        let persistence = MockPersistenceService()
        let kit = PositronicKit(configuration: .init(
            provider: .init(languageModel: llm),
            persistence: .init(
                runtimeRepository: persistence,
                workspacePersistence: persistence,
                toolPersistence: persistence,
                agentStore: persistence,
                requestOriginStore: persistence
            )
        ))
        let threadID = UUID()
        let request = TurnRequest(
            threadID: threadID,
            message: "speak",
            responseModalities: [.audio],
            audioOutput: .init(format: .wav, voice: "alloy")
        )

        do {
            _ = try await kit.startTurnHandle(request, agentID: nil, executionKind: .direct)
            Issue.record("\(id): expected runtime ordering rejection")
        } catch let error as MultimodalContentError {
            #expect(error == expected, "\(id)")
        } catch {
            Issue.record("\(id): unexpected error \(error)")
        }

        #expect(persistence.persistenceAccessCount == 0, "\(id): persistence was accessed")
        #expect(llm.generationRequestHistory.isEmpty, "\(id): provider generation request occurred")
        #expect(llm.mockClient.generationCaptureHistory.isEmpty, "\(id): low-level provider request occurred")
        #expect(persistence.messages.isEmpty, "\(id): user message was persisted")
        #expect(persistence.threads.isEmpty, "\(id): thread admission was persisted")
        #expect(await kit.turnEngine.dependencies.promptHistoryRegistry.containsHistory(for: threadID) == false, "\(id): prompt history was created")
    }
}

private struct MatrixFoundationModelsSession: FoundationModelsSessionProtocol {
    nonisolated func streamTurn(prompt _: String) -> AsyncThrowingStream<FoundationModelsSessionEvent, Error> {
        AsyncThrowingStream { continuation in continuation.finish() }
    }
}
