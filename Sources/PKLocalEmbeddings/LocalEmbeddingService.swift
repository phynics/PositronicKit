import Foundation
import PKShared
import PositronicKit

#if canImport(NaturalLanguage)
import NaturalLanguage
#endif

/// Public facade for platform-local embeddings.
public final class LocalEmbeddingService: EmbeddingServiceProtocol, Sendable {
    private let backend: LocalEmbeddingBackend
    public let inputBudget: EmbeddingInputBudget

    /// Default local embedding request budget enforced before inference.
    public static let defaultInputBudget = EmbeddingInputBudget.default

    package var backendIdentifier: LocalEmbeddingBackendKind {
        backend.kind
    }

    package var backendInputBudget: EmbeddingInputBudget {
        switch backend {
        case .naturalLanguage:
            inputBudget
        case let .miniLM(backend):
            backend.inputBudget
        }
    }

    #if os(Linux)
    public init(
        modelDirectory: URL,
        inputBudget: EmbeddingInputBudget = .default
    ) throws {
        self.inputBudget = inputBudget
        self.backend = try .miniLM(
            MiniLMEmbeddingBackend(modelDirectory: modelDirectory, inputBudget: inputBudget)
        )
    }
    #else
    public init(inputBudget: EmbeddingInputBudget = .default) {
        self.backend = .naturalLanguage
        self.inputBudget = inputBudget
    }

    #if MiniLMEmbeddings
    public init(
        miniLMModelDirectory: URL,
        inputBudget: EmbeddingInputBudget = .default
    ) throws {
        self.inputBudget = inputBudget
        self.backend = try .miniLM(
            MiniLMEmbeddingBackend(modelDirectory: miniLMModelDirectory, inputBudget: inputBudget)
        )
    }
    #endif
    #endif

    public func generateEmbedding(for text: String) async throws -> [Float] {
        try validate(text)
        return try await backend.generateEmbedding(for: text)
    }

    public func generateEmbeddings(for texts: [String]) async throws -> [[Float]] {
        try validate(texts)
        return try await backend.generateEmbeddings(for: texts)
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
