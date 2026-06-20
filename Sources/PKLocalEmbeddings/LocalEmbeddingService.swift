import Foundation
import PositronicKit

#if canImport(NaturalLanguage)
import NaturalLanguage
#endif

/// Public facade for platform-local embeddings.
public final class LocalEmbeddingService: EmbeddingServiceProtocol, Sendable {
    private let backend: LocalEmbeddingBackend

    package var backendIdentifier: LocalEmbeddingBackendKind {
        backend.kind
    }

    #if os(Linux)
    public init(modelDirectory: URL) throws {
        self.backend = try .miniLM(MiniLMEmbeddingBackend(modelDirectory: modelDirectory))
    }
    #else
    public init() {
        self.backend = .naturalLanguage
    }

    #if MiniLMEmbeddings
    public init(miniLMModelDirectory: URL) throws {
        self.backend = try .miniLM(MiniLMEmbeddingBackend(modelDirectory: miniLMModelDirectory))
    }
    #endif
    #endif

    public func generateEmbedding(for text: String) async throws -> [Float] {
        try await backend.generateEmbedding(for: text)
    }

    public func generateEmbeddings(for texts: [String]) async throws -> [[Float]] {
        try await backend.generateEmbeddings(for: texts)
    }
}
