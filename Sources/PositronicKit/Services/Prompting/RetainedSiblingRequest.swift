import Foundation
import PKContracts

/// The final model round's provider-neutral request, retained per Timeline so a host can issue a
/// cache-exact sibling request (issue #281).
///
/// The value is immutable, bounded to the newest round only, released with the Timeline's
/// prompt-history entry on eviction or deletion, and never logged. It is populated only when
/// ``PKRuntime/RuntimeConfiguration/retainsSiblingPrefix`` is enabled. Hosts never observe this
/// type directly: they reach it through ``TimelineHandle/siblingRequest(appending:responseFormat:generationParameters:)``.
struct RetainedSiblingRequest: Sendable {
    /// The messages the retained round sent, in wire order.
    let messages: [LLMMessage]
    /// The tool catalog the retained round offered, or `nil` when it offered none.
    let tools: [LLMToolDefinition]?
    /// The tool-selection constraint the retained round sent, if any.
    let toolChoice: LLMToolChoice?
    /// The response shape the retained round requested, if any.
    let responseFormat: LLMResponseFormat?
    /// The effective generation parameters the retained round sent, if any.
    let generationParameters: GenerationParameters?
    /// The cache directive the retained round sent, including its routing key and breakpoints.
    let promptCache: PromptCacheDirective?
    /// The model tier the retained round targeted.
    let modelTier: ModelTier
    /// The transport the retained round used.
    let transport: GenerationTransport

    /// Captures the request the given model round actually sent to the provider.
    ///
    /// The messages, tools, effective generation parameters, and cache directive are exactly the
    /// values `LLMStreamingStage` builds for the round, so replaying them reproduces the same
    /// provider-facing prefix byte for byte.
    static func capture(from context: TurnContext) -> RetainedSiblingRequest {
        RetainedSiblingRequest(
            messages: context.currentMessages,
            tools: context.toolParams.isEmpty ? nil : context.toolParams,
            toolChoice: nil,
            responseFormat: nil,
            generationParameters: context.generationParameters,
            promptCache: LLMStreamingStage.promptCacheDirective(for: context),
            modelTier: .primary,
            transport: context.transport
        )
    }
}
