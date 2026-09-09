import Foundation

/// A non-network snapshot of whether a model client can be used by the runtime.
public enum ModelReadiness: Sendable, Equatable {
    /// The client reports valid configuration and a usable primary client.
    case ready

    /// The runtime cannot use the model client at this moment.
    case unavailable(ModelReadinessReason)
}

/// Why a model is not ready for inference.
public enum ModelReadinessReason: Sendable, Equatable {
    /// The provider configuration is incomplete or invalid.
    case invalidConfiguration

    /// Configuration is valid, but no usable primary client is available.
    case clientUnavailable
}
