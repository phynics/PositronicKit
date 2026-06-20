import Foundation
import PositronicKit

#if os(Linux)
import PKMiniLMLinuxBackend
private typealias PlatformMiniLMBackend = PKMiniLMPlatformBackend
#elseif MiniLMEmbeddings
import PKMiniLMTraitBackend
private typealias PlatformMiniLMBackend = PKMiniLMPlatformBackend
#endif

package struct MiniLMEmbeddingBackend: Sendable {
    #if os(Linux) || MiniLMEmbeddings
    private let model: PlatformMiniLMBackend
    #endif

    package init(modelDirectory: URL) throws {
        #if os(Linux) || MiniLMEmbeddings
        try MiniLMModelAssets.validate(modelDirectory: modelDirectory)
        self.model = try PlatformMiniLMBackend(modelDirectory: modelDirectory)
        #else
        _ = modelDirectory
        throw EmbeddingError.modelUnavailable
        #endif
    }

    package func generateEmbedding(for text: String) async throws -> [Float] {
        #if os(Linux) || MiniLMEmbeddings
        return try await model.generateEmbedding(for: text)
        #else
        _ = text
        throw EmbeddingError.modelUnavailable
        #endif
    }

    package func generateEmbeddings(for texts: [String]) async throws -> [[Float]] {
        #if os(Linux) || MiniLMEmbeddings
        return try await model.generateEmbeddings(for: texts)
        #else
        _ = texts
        throw EmbeddingError.modelUnavailable
        #endif
    }
}
