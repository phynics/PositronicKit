import Foundation
import PKContracts

/// Operational readiness of an LLM service, projected from one runtime snapshot.
///
/// Every health, send, stream, and model-listing path consumes this same state so the
/// service never reports conflicting readiness.
enum LLMReadiness: Sendable, Equatable {
    case invalidConfiguration
    case clientUnavailable(provider: LLMProvider)
    case ready
}

/// The atomic runtime state an `LLMService` owns: one configuration plus the client set
/// resolved for it.
///
/// All configuration transitions replace the snapshot wholesale, so the service never
/// observes a configuration/client mismatch (for example, dispatching an injected client
/// while reporting metadata from a different provider).
struct LLMRuntimeSnapshot: Sendable {
    let configuration: LLMConfiguration
    let clients: LLMClientSet

    /// A valid configuration is required even when a primary client is present: the client
    /// may have been built for a different provider or stale credentials.
    var readiness: LLMReadiness {
        guard configuration.isValid else {
            return .invalidConfiguration
        }
        guard clients.primary != nil else {
            return .clientUnavailable(provider: configuration.activeProvider)
        }
        return .ready
    }
}

/// A resolved client plus the generation-parameter defaults its configuration implies.
///
/// Produced once by `LLMService.resolve(tier:)` and consumed by every dispatch path.
struct ResolvedLLMClient {
    let client: any LLMClientProtocol
    let generationParameters: GenerationParameters
}
