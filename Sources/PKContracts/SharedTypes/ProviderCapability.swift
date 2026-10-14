import Foundation

/// How a provider adapter can honor a ``PromptCacheDirective``.
///
/// Adapters declare a capability so the runtime can skip breakpoint planning for providers that
/// expose no cache, and so the provider capability matrix can report support.
public enum PromptCachingCapability: Sendable, Equatable {
    /// The provider exposes no prompt caching; directives are dropped.
    case none
    /// The provider caches prefixes automatically. A directive's routing key can improve hit
    /// rates, but explicit breakpoints are ignored.
    case automatic
    /// The provider caches only explicitly marked prefix boundaries. The associated value is the
    /// maximum number of breakpoints the provider honors per request.
    case explicit(maxBreakpoints: Int)
}

/// A provider option that was not preserved exactly by the adapter.
public struct ProviderCapabilityWarning: Sendable, Equatable {
    public enum Category: String, Sendable, Codable {
        case tools
        case toolChoice
        case responseFormat
        case generationParameters
    }

    public let provider: LLMProvider
    public let model: String
    public let category: Category
    public let reason: String

    public init(provider: LLMProvider, model: String, category: Category, reason: String) {
        self.provider = provider
        self.model = model
        self.category = category
        self.reason = reason
    }
}

/// Computes safe, payload-free capability warnings for a single generation turn.
public enum ProviderCapabilityObservability {
    public static func warnings(
        provider: LLMProvider,
        model: String,
        hasTools: Bool,
        hasResponseFormat: Bool,
        generationParameters: GenerationParameters?
    ) -> [ProviderCapabilityWarning] {
        var result: [ProviderCapabilityWarning] = []

        if hasTools, provider == .anthropic {
            // Anthropic receives tools through its native input_schema representation; tool choice
            // is coerced by the adapter when a named choice is requested.
        }
        if hasResponseFormat, provider == .anthropic {
            result.append(.init(
                provider: provider,
                model: model,
                category: .responseFormat,
                reason: "Anthropic Messages has no native response_format; structured output uses the synthetic-tool path."
            ))
        }
        if generationParameters?.seed != nil, provider == .anthropic || provider == .ollama {
            result.append(.init(
                provider: provider,
                model: model,
                category: .generationParameters,
                reason: "The adapter does not send seed because this provider does not expose a compatible request field."
            ))
        }
        return result
    }
}
