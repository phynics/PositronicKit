import Foundation

/// Selects the provider transport a generation request uses.
///
/// Streaming is the canonical runtime transport and the default everywhere. A
/// request-response provider returns the whole response as one terminal `LLMStreamChunk`,
/// so every downstream consumer — tool-call accumulation, structured output, and Turn
/// durability — sees the same chunk contract and needs no transport-specific branch.
public enum GenerationTransport: Sendable, Equatable {
    /// Streams incremental chunks from the provider.
    case streaming

    /// Requests one complete response and delivers it as a single terminal chunk.
    case requestResponse
}
