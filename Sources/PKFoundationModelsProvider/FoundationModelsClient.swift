import Foundation
import Logging
import PKShared
import PKUtilities

#if canImport(FoundationModels)
    import FoundationModels
#endif

/// `LLMClientProtocol` adapter over Apple's on-device Foundation Models framework (PKPOST-003).
///
/// Unlike the HTTP-family adapters (`AnthropicClient`, `OpenAIClient`, ...), there is no wire
/// protocol here: `LanguageModelSession` is a local Swift API. This client drives a
/// `FoundationModelsSessionProtocol` (either the live session wrapper or, in tests, a scripted
/// fake) and maps its event sequence to `LLMStreamChunk`s via `FoundationModelsStreamMapper`.
///
/// No API key, no network, no retries: on-device generation either succeeds, or fails with a
/// typed, non-transient error (availability, guardrail, context-window) that retrying would not
/// fix, so `RetryPolicy` is intentionally not used here.
///
/// Available unconditionally (not `#if canImport(FoundationModels)`-guarded itself) so the type
/// exists for tests on any host; the default live-session factory is only wired up on hosts that
/// have the framework (`canImport(FoundationModels)`), matching PKPOST-003's "package remains
/// green on hosts without FoundationModels" requirement. Callers on unsupported hosts must
/// supply their own `makeSession` (e.g. a fake) or the client throws `unsupportedPlatform` on use.
public actor FoundationModelsClient: LLMClientProtocol {
    /// Factory for the per-turn session: given the tool definitions PositronicKit resolved for
    /// this turn and the hoisted system-instructions string, produce a session to drive.
    /// PositronicKit's `[LLMToolDefinition]` (JSON-Schema-shaped, transport-neutral) is bridged
    /// to the framework's typed `Tool` protocol by the production factory; tests pass their own
    /// factory and can ignore `tools` entirely for text-only fixtures.
    public typealias SessionFactory = @Sendable (
        _ tools: [LLMToolDefinition]?,
        _ instructions: String?
    ) -> any FoundationModelsSessionProtocol

    private let modelName: String
    private let logger = Logger.module(named: "foundation-models-client")
    private let makeSession: SessionFactory?

    /// - Parameters:
    ///   - modelName: Informational label surfaced on `LLMStreamChunk.model`; Foundation Models
    ///     does not expose a model name/id to select between (there is exactly one on-device
    ///     system model), so this is caller-supplied metadata only.
    ///   - tools: Executable tools bridged into the session via `PKBridgedFMTool` so the
    ///     framework can actually call them. **Not** the same as the per-turn
    ///     `[LLMToolDefinition]` `chatStream` receives from `ToolRouter` — `LLMClientProtocol`'s
    ///     shared contract only carries schema (name/description/parameters), never an executor,
    ///     because the HTTP-family adapters never execute tools themselves (the caller executes
    ///     them after a `tool_calls` finish and resends results as `tool`-role messages).
    ///     `LanguageModelSession` is different: it executes registered `Tool`s itself while
    ///     producing a response, so it needs the executable tool up front, at session-construction
    ///     time — not per-turn. Passing `tools` here is the documented way to get real on-device
    ///     tool execution; per-turn `[LLMToolDefinition]` from `chatStream` is only used for the
    ///     ignored-parameter diagnostics below when `tools` is empty (see README support matrix).
    ///   - makeSession: Factory for the per-turn session. Defaults to the live `FoundationModels`
    ///     session wrapper (primed with `tools`, bridged via `PKBridgedFMTool`) on hosts where the
    ///     framework is available; pass a fake here in tests, or on unsupported hosts where
    ///     `chatStream` otherwise throws `FoundationModelsPlatformError.unsupportedPlatform`.
    public init(
        modelName: String = "apple-on-device",
        tools: [AnyTool] = [],
        makeSession: SessionFactory? = nil
    ) {
        self.modelName = modelName
        if let makeSession {
            self.makeSession = makeSession
        } else {
            #if canImport(FoundationModels)
                if #available(macOS 26.0, *) {
                    self.makeSession = { _, instructions in
                        LiveFoundationModelsSession(bridging: tools, instructions: instructions)
                    }
                } else {
                    self.makeSession = nil
                }
            #else
                self.makeSession = nil
            #endif
        }
    }

    public func chatStream(
        messages: [LLMMessage],
        tools: [LLMToolDefinition]?,
        toolChoice: LLMToolChoice?,
        responseFormat: LLMResponseFormat?,
        generationParameters: GenerationParameters?
    ) async -> AsyncThrowingStream<LLMStreamChunk, Error> {
        let modelName = self.modelName
        let logger = self.logger

        if let responseFormat, responseFormat != .text {
            logger.warning(
                "FoundationModels adapter maps only free-text responses today; \(String(describing: responseFormat)) is ignored."
            )
        }
        if toolChoice != nil {
            logger.debug("FoundationModels ignores toolChoice (no forced-tool equivalent); tools remain auto-selectable by the model.")
        }
        if tools?.isEmpty == false {
            logger.debug(
                "Per-turn [LLMToolDefinition] schema is not usable for on-device execution (no executor carried by the shared contract); pass executable AnyTools to FoundationModelsClient.init(tools:) instead."
            )
        }
        logGenerationParameterGaps(generationParameters, logger: logger)

        let instructions = systemInstructions(from: messages)
        let userPrompt = latestUserPrompt(from: messages)
        let messageID = UUID().uuidString

        guard let session = resolveSession(tools: tools, instructions: instructions) else {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: FoundationModelsPlatformError.unsupportedPlatform)
            }
        }

        return AsyncThrowingStream { continuation in
            let task = Task {
                var state = FoundationModelsStreamMapper.State()
                do {
                    for try await event in session.streamTurn(prompt: userPrompt) {
                        if Task.isCancelled { break }
                        if let chunk = FoundationModelsStreamMapper.map(
                            event,
                            model: modelName,
                            messageID: messageID,
                            state: &state
                        ) {
                            continuation.yield(chunk)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private nonisolated func resolveSession(
        tools: [LLMToolDefinition]?,
        instructions: String?
    ) -> (any FoundationModelsSessionProtocol)? {
        makeSession?(tools, instructions)
    }

    public func fetchAvailableModels() async throws -> [String]? {
        // Exactly one on-device system model exists; there is nothing to list.
        [modelName]
    }

    // MARK: - Message shaping

    /// Hoists `system`/`developer` role content into a single instructions string, mirroring
    /// how the Anthropic adapter hoists `system` out of the alternating user/assistant sequence
    /// (`AnthropicMessageConversion.convert`). Returns `nil` when there is none, so the session
    /// factory can fall back to `LanguageModelSession`'s default (no instructions).
    private nonisolated func systemInstructions(from messages: [LLMMessage]) -> String? {
        let parts = messages
            .filter { $0.role == .system || $0.role == .developer }
            .map(\.content)
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    /// Foundation Models sessions accumulate history in their own `Transcript` rather than
    /// taking a full message array per turn (unlike the HTTP-family adapters, which resend the
    /// full history every request). This adapter targets single-turn on-device generation
    /// (PKPOST-003 scope); the latest user message is what's sent to `streamTurn`. Multi-turn
    /// session reuse across PositronicKit turns is a documented gap — see README support matrix.
    private nonisolated func latestUserPrompt(from messages: [LLMMessage]) -> String {
        messages.last(where: { $0.role == .user })?.content ?? ""
    }

    private nonisolated func logGenerationParameterGaps(
        _ parameters: GenerationParameters?,
        logger: Logger
    ) {
        guard let parameters else { return }
        if parameters.topP != nil || parameters.frequencyPenalty != nil
            || parameters.presencePenalty != nil
        {
            logger.debug(
                "FoundationModels ignores topP/frequencyPenalty/presencePenalty (GenerationOptions has no equivalents; only temperature, maxTokens→maximumResponseTokens, and seed→sampling(top:seed:) map)."
            )
        }
    }
}

/// Thrown when `FoundationModelsClient` has no session factory to use — the framework is
/// unavailable at compile time (`#if canImport(FoundationModels)` false, e.g. Linux or a
/// pre-26 Apple OS in the build SDK) and no fake `makeSession` was supplied. Never a crash or
/// silent empty stream (PKPOST-003 requirement); this is distinct from
/// `FoundationModelsAvailabilityError`, which covers the framework being present at compile time
/// but unavailable at runtime (Apple Intelligence disabled, device ineligible, etc.).
public enum FoundationModelsPlatformError: PKError, Equatable {
    case unsupportedPlatform

    public var errorDomain: String {
        PKErrorDomain.llm
    }

    public var errorCode: Int {
        2201
    }

    public var userFriendlyMessage: String {
        "The on-device Foundation Models framework is not available on this build/host."
    }

    public var remediation: String? {
        "Use a different provider, or run on macOS 26+ with the FoundationModels SDK available."
    }
}
