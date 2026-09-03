import Foundation
import PKAnthropicProvider
import PKContracts
import PKFoundationModelsProvider
import PKObservable
import PKOllamaProvider
import PKOpenAIProvider
import PKOpenRouterProvider
import PKPrompt
import PKTestSupport
import PositronicKit

private struct StreamOnlyLLMClient: LLMStreamClient {
    var isConfigured: Bool {
        get async { true }
    }

    var configuration: LLMConfiguration {
        get async { .openAI }
    }

    func generationStream(
        messages _: [LLMMessage],
        tools _: [LLMToolDefinition]?,
        toolChoice _: LLMToolChoice?,
        responseFormat _: LLMResponseFormat?,
        generationParameters _: GenerationParameters?,
        modelTier _: ModelTier
    ) async -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }
}

// This target is intentionally small: its job is to prove that every public library
// product remains consumable through ordinary imports, without @testable access.
_ = String(describing: PositronicKit.self)
_ = String(describing: (any Prompt).self)
_ = String(describing: Message.self)
_ = String(describing: ThreadController.self)
_ = String(describing: PKOpenAIProvider.self)
_ = String(describing: PKOpenRouterProvider.self)
_ = String(describing: PKOllamaProvider.self)
_ = String(describing: PKAnthropicProvider.self)
_ = String(describing: PKFoundationModelsProvider.self)
_ = String(describing: TestRuntime.self)

let kit = PositronicKit()
_ = kit.model
_ = kit.threads
_ = kit.agents
_ = kit.workspaces
_ = String(describing: ThreadHandle.self)

// A stream-only implementation is sufficient for the facade and strict utility generator;
// configuration administration and health capabilities are deliberately not required here.
private let streamOnly = StreamOnlyLLMClient()
let streamConfiguredKit = PositronicKit(configuration: .init(
    provider: .init(languageModel: streamOnly),
    persistence: .inMemory()
))
_ = streamConfiguredKit.model
_ = LLMUtilityGenerator(streamClient: streamOnly)

// E-01 regression gate: `Configuration.logging` must be constructible by a consumer that only
// imports PositronicKit — `LoggingConfiguration` and `LogRedactionPolicy` must be nameable
// without @testable access. A non-default value (custom redaction policy and logger factory)
// is required here; naming the type alone is not enough to catch a type that consumers can only
// ever default.
let customLoggingConfiguration = LoggingConfiguration(
    redactionPolicy: LogRedactionPolicy(logsPayloads: true)
)
let loggingConfiguredKit = PositronicKit(configuration: .init(
    provider: .init(languageModel: streamOnly),
    persistence: .inMemory(),
    logging: customLoggingConfiguration
))
_ = loggingConfiguredKit.model
