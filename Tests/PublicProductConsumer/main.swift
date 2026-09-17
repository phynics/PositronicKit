import Foundation
import JSONSchemaBuilder
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
        modelTier _: ModelTier,
        responseModalities _: Set<ResponseModality>,
        audioOutput _: AudioOutputOptions?
    ) async -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }
}

// This target is intentionally small: its job is to prove that every public library
// product remains consumable through ordinary imports, without @testable access.
_ = String(describing: PKRuntime.self)
// SE-0491 module selectors (ADR 0012): the docs-snippet gate type-checks the shadowed
// spelling, and this proves the same selector resolves to the shipped facade from a
// downstream consumer that imports PositronicKit normally.
_ = String(describing: PositronicKit::PKRuntime.self)
_ = String(describing: (any Prompt).self)
_ = String(describing: Message.self)
_ = String(describing: TimelineRecord.self)
_ = String(describing: (any PKTool).self)
_ = String(describing: TimelineController.self)
_ = String(describing: PKOpenAI.self)
_ = String(describing: PKOpenRouter.self)
_ = String(describing: PKOllama.self)
_ = String(describing: PKAnthropic.self)
_ = PKOpenAIProvider.OpenAIClient.self
_ = PKOpenRouterProvider.OpenRouterClient.self
_ = PKOllamaProvider.OllamaClient.self
_ = PKAnthropicProvider.AnthropicClient.self
_ = PKFoundationModelsProvider.FoundationModelsClient.self
_ = String(describing: TestRuntime.self)

let kit = PKRuntime()
_ = kit.model
_ = kit.timelines
_ = kit.agents
_ = kit.workspaces
_ = String(describing: TimelineHandle.self)

@Schemable
struct PublicTypedStructuredPayload: Decodable, Sendable {
    let projectName: String

    enum CodingKeys: String, CodingKey {
        case projectName = "project_name"
    }
}

// Ordinary-import compile coverage for the typed one-shot structured-generation API.
func exercisePublicTypedStructuredGeneration() async {
    _ = try? await kit.model.generate(
        PublicTypedStructuredPayload.self,
        from: "Extract the project name."
    )
}

// Ordinary-import compile coverage for the raw-payload structured-generation API.
func exercisePublicStructuredPayloadGeneration() async {
    _ = try? await kit.model.generate(
        "Extract the project name.",
        structuredOutput: .jsonObject
    )
}

// Ordinary-import compile coverage for the durable Timeline history capability.
func exercisePublicTimelineHistory(_ timelineID: UUID) async {
    _ = try? await kit.timelines.messages(for: timelineID)
}

// Ordinary-import compile coverage for the canonical managed/direct admission overloads.
func exercisePublicTurnAdmission(_ timeline: TimelineHandle) async {
    let content = MessageContent(parts: [
        .text("Describe this image."),
        .image(ImageContent(data: Data([0x01]), mediaType: "image/png")),
    ])
    _ = try? await timeline.startTurn("Hello", options: TurnOptions())
    _ = try? await timeline.startTurn(content, systemInstructions: "Be concise.")
    _ = try? await timeline.startDirectTurn(
        "Hello directly",
        context: DirectTurnContext(systemInstructions: "Be concise."),
        options: TurnOptions())
    _ = try? await timeline.startDirectTurn(
        content,
        context: DirectTurnContext(systemInstructions: "Be concise.", contributor: .host))
}

// Ordinary-import compile coverage for both `TimelineController` admission paths.
@MainActor
func exerciseTimelineControllerPaths(_ managed: TimelineHandle, direct: TimelineHandle) {
    _ = TimelineController(managed)
    _ = TimelineController(direct, context: DirectTurnContext(systemInstructions: "Be concise."))
}

// Provider packages return one runtime-neutral value for ordinary application setup.
let configuredProvider = PKOpenAI.makeConfiguredProvider(apiKey: "test-key")
let configuredKit = PKRuntime(provider: configuredProvider)
_ = configuredKit.model

// The durable provider path keeps `LLMService` and `LLMClientSet` out of consumer code too:
// the same configured value feeds a grouped `Configuration` with explicit persistent stores.
let durableConfiguredKit = PKRuntime(configuration: .init(
    provider: configuredProvider,
    persistence: .fullyPersistent(
        runtimeRepository: InMemoryTimelineRuntimeRepository(),
        workspacePersistence: InMemoryWorkspacePersistence(),
        toolPersistence: InMemoryToolPersistence(),
        agentStore: InMemoryAgentStore(),
        requestOriginStore: InMemoryRequestOriginStore()
    )
))
_ = durableConfiguredKit.model

// A stream-only implementation is sufficient for the facade and strict utility generator;
// configuration administration and health capabilities are deliberately not required here.
private let streamOnly = StreamOnlyLLMClient()
let streamConfiguredKit = PKRuntime(configuration: .init(
    languageModel: streamOnly,
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
let loggingConfiguredKit = PKRuntime(configuration: .init(
    languageModel: streamOnly,
    persistence: .inMemory(),
    logging: customLoggingConfiguration
))
_ = loggingConfiguredKit.model
