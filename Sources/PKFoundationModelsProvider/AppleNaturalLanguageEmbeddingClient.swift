#if canImport(NaturalLanguage)
import Foundation
import NaturalLanguage
import PKContracts

/// `EmbeddingClientProtocol` adapter over Apple's Natural Language sentence embeddings.
///
/// `NLEmbedding.sentenceEmbedding(for:)` is an on-device model. There is no network transport and
/// no retry: a missing model or an unvectorizable input is a typed, non-transient failure. The
/// adapter ignores ``EmbeddingPurpose`` because sentence embeddings are symmetric.
///
/// The whole file is guarded by `#if canImport(NaturalLanguage)` so non-Apple hosts compile
/// without the type.
public actor AppleNaturalLanguageEmbeddingClient: EmbeddingClientProtocol {
    public nonisolated let inputBudget: EmbeddingInputBudget

    /// The BCP-47 language code whose sentence embedding model this client uses.
    public nonisolated let languageCode: String

    /// Creates a client for the sentence embedding model of `language`.
    ///
    /// - Parameters:
    ///   - language: The Natural Language language whose model to use. Defaults to English.
    ///   - inputBudget: The request budget enforced before I/O.
    public init(
        language: NLLanguage = .english,
        inputBudget: EmbeddingInputBudget = .default
    ) {
        self.languageCode = language.rawValue
        self.inputBudget = inputBudget
    }

    public func embed(_ request: EmbeddingRequest) async throws -> EmbeddingResponse {
        try inputBudget.validate(request.inputs)

        let language = NLLanguage(rawValue: languageCode)
        guard let sentenceEmbedding = NLEmbedding.sentenceEmbedding(for: language) else {
            throw EmbeddingError.modelUnavailable
        }

        let embeddings = try request.inputs.map { text -> Embedding in
            guard let vector = sentenceEmbedding.vector(for: text) else {
                throw EmbeddingError.generationFailed
            }
            let floatVector = vector.map(Float.init)
            return Embedding(
                vector: floatVector,
                space: EmbeddingSpace(
                    provider: "apple-nl",
                    model: language.rawValue,
                    dimensions: floatVector.count,
                    isNormalized: true
                )
            )
        }

        return EmbeddingResponse(embeddings: embeddings)
    }
}

#endif
