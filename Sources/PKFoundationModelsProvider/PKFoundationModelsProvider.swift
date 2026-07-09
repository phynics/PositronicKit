import Foundation
import PKShared
import PositronicKit

/// Convenience registration/init for Apple's on-device Foundation Models provider (PKPOST-003).
///
/// Unlike `PKAnthropicProvider`/`PKOpenAIProvider`/`PKOllamaProvider`, this adapter has no API
/// key, endpoint, or wire config — `ExternalLLMProviderRegistry`'s factory shape
/// (`(ProviderFactoryRequest) -> LLMClientProtocol?`) exists to parameterize *HTTP* provider
/// construction and doesn't fit an on-device session. So `PositronicKit(foundationModelsTools:)`
/// below constructs an `LLMService` directly from a `FoundationModelsClient`, bypassing the
/// registry/`LLMConfiguration` path entirely, rather than registering a factory that would just
/// ignore most of its parameters.
public enum PKFoundationModelsProvider {
    /// Present for parity with the other provider modules' `register()` entry point, but
    /// intentionally a no-op: there is nothing to register into `ExternalLLMProviderRegistry`
    /// (no `LLMProvider.foundationModels` case — the registry is keyed by config-driven HTTP
    /// providers). Construct a runtime via `PositronicKit(foundationModelsTools:)` instead.
    public static func register() {}
}

public extension PositronicKit {
    /// Builds a runtime backed by the on-device Foundation Models provider.
    ///
    /// - Parameter tools: Executable tools to bridge into the on-device session (see
    ///   `FoundationModelsClient.init(tools:)` — the framework executes tools itself while
    ///   producing a response, so they must be supplied up front rather than per-turn).
    /// - Note: `tools` has no default value on purpose: a fully-defaulted parameter list would
    ///   make bare `PositronicKit()` ambiguous with (and in practice silently resolve to) this
    ///   initializer for any module importing the provider, changing what "default init" means.
    ///   Pass `[]` explicitly for a tool-less on-device runtime.
    convenience init(foundationModelsTools tools: [AnyTool]) {
        let client = FoundationModelsClient(tools: tools)
        let llm = LLMService(
            storage: InMemoryConfigurationService(config: .default),
            client: client,
            utilityClient: client,
            fastClient: client
        )
        self.init(llmService: llm)
    }
}
