import Foundation
import PKShared
import PKUtilities
import PositronicKit

#if os(Linux) || MiniLMEmbeddings
import PKFastEmbed
#endif

#if canImport(NaturalLanguage)
import NaturalLanguage
#endif

package enum LocalEmbeddingBackendKind: String, Sendable {
    case naturalLanguage
    case miniLM
}

/// Public facade for platform-local embeddings.
public final class LocalEmbeddingService: EmbeddingServiceProtocol, Sendable {
    #if os(Linux) || MiniLMEmbeddings
    private let miniLMBackend: PKMiniLMPlatformBackend?
    #endif
    public let inputBudget: EmbeddingInputBudget

    /// Default local embedding request budget enforced before inference.
    public static let defaultInputBudget = EmbeddingInputBudget.default

    package var backendIdentifier: LocalEmbeddingBackendKind {
        #if os(Linux) || MiniLMEmbeddings
        return miniLMBackend != nil ? .miniLM : .naturalLanguage
        #else
        return .naturalLanguage
        #endif
    }

    package var backendInputBudget: EmbeddingInputBudget {
        inputBudget
    }

    #if os(Linux) || MiniLMEmbeddings
    /// Creates a local embedding service backed by the MiniLM model at the supplied directory.
    public init(
        miniLMModelDirectory: URL,
        inputBudget: EmbeddingInputBudget = .default
    ) throws {
        self.inputBudget = inputBudget
        try MiniLMModelAssets.validate(modelDirectory: miniLMModelDirectory)
        self.miniLMBackend = try PKMiniLMPlatformBackend(
            modelDirectory: miniLMModelDirectory,
            inputBudget: inputBudget
        )
    }

    #if os(Linux)
    /// Creates a local embedding service backed by the MiniLM model at the supplied directory.
    @available(*, deprecated, renamed: "init(miniLMModelDirectory:inputBudget:)")
    public convenience init(
        modelDirectory: URL,
        inputBudget: EmbeddingInputBudget = .default
    ) throws {
        try self.init(
            miniLMModelDirectory: modelDirectory,
            inputBudget: inputBudget
        )
    }
    #endif
    #endif

    #if !os(Linux)
    public init(inputBudget: EmbeddingInputBudget = .default) {
        #if MiniLMEmbeddings
        self.miniLMBackend = nil
        #endif
        self.inputBudget = inputBudget
    }
    #endif

    public func generateEmbedding(for text: String) async throws -> [Float] {
        try validate(text)
        #if os(Linux) || MiniLMEmbeddings
        if let miniLMBackend {
            return try await miniLMBackend.generateEmbedding(for: text)
        }
        #endif
        return try naturalLanguageEmbedding(for: text)
    }

    public func generateEmbeddings(for texts: [String]) async throws -> [[Float]] {
        try validate(texts)
        #if os(Linux) || MiniLMEmbeddings
        if let miniLMBackend {
            return try await miniLMBackend.generateEmbeddings(for: texts)
        }
        #endif
        var results: [[Float]] = []
        results.reserveCapacity(texts.count)
        for text in texts {
            results.append(try naturalLanguageEmbedding(for: text))
        }
        return results
    }

    private func naturalLanguageEmbedding(for text: String) throws -> [Float] {
        #if canImport(NaturalLanguage)
        guard let embedding = NLEmbedding.sentenceEmbedding(for: .english) else {
            throw EmbeddingError.modelUnavailable
        }
        guard let vector = embedding.vector(for: text) else {
            throw EmbeddingError.generationFailed
        }
        return vector.map { Float($0) }
        #else
        _ = text
        throw EmbeddingError.modelUnavailable
        #endif
    }

    private func validate(_ text: String) throws {
        do {
            try inputBudget.validate(text)
        } catch let error as EmbeddingInputBudget.ValidationError {
            throw mapValidationError(error)
        }
    }

    private func validate(_ texts: [String]) throws {
        do {
            try inputBudget.validate(texts)
        } catch let error as EmbeddingInputBudget.ValidationError {
            throw mapValidationError(error)
        }
    }

    private func mapValidationError(_ error: EmbeddingInputBudget.ValidationError) -> EmbeddingError {
        switch error {
        case let .batchTextCountLimitExceeded(max, actual):
            return .batchTextCountLimitExceeded(max: max, actual: actual)
        case let .perTextByteLimitExceeded(max, actual):
            return .perTextByteLimitExceeded(max: max, actual: actual)
        case let .totalBatchByteLimitExceeded(max, actual):
            return .totalBatchByteLimitExceeded(max: max, actual: actual)
        }
    }
}
