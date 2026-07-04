import Foundation
import PKShared
import PositronicKit

#if os(Linux) || MiniLMEmbeddings
    import PKFastEmbed

    private typealias PlatformMiniLMBackend = PKMiniLMPlatformBackend
#endif

package struct MiniLMEmbeddingBackend {
    #if os(Linux) || MiniLMEmbeddings
        private let model: PlatformMiniLMBackend
    #endif
    package let inputBudget: EmbeddingInputBudget

    package init(
        modelDirectory: URL,
        inputBudget: EmbeddingInputBudget = .default
    ) throws {
        self.inputBudget = inputBudget
        #if os(Linux) || MiniLMEmbeddings
            try MiniLMModelAssets.validate(modelDirectory: modelDirectory)
            model = try PlatformMiniLMBackend(
                modelDirectory: modelDirectory,
                inputBudget: inputBudget
            )
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
