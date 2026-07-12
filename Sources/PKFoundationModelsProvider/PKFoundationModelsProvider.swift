import Foundation
import PKShared
import PositronicKit

/// Convenience registration/init for Apple's on-device Foundation Models provider (PKPOST-003).
///
/// This adapter has no API key, endpoint, or wire configuration: it constructs an `LLMService`
/// directly from a `FoundationModelsClient`.
public enum PKFoundationModelsProvider {
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
    convenience init(foundationModelsTools tools: [any Tool]) {
        let client = FoundationModelsClient(tools: tools.map { $0.toAnyTool() })
        let llm = LLMService(
            storage: InMemoryConfigurationService(config: .default),
            client: client,
            utilityClient: client,
            fastClient: client
        )
        self.init(configuration: .init(
            provider: .init(languageModel: llm),
            persistence: .inMemory()
        ))
    }
}
