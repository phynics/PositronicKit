import Foundation
@_spi(Experimental) import PKContracts
@_spi(Experimental) import PKOpenAIProvider
@_spi(Experimental) import PKOllamaProvider
@_spi(Experimental) import PKTestSupport
#if canImport(NaturalLanguage)
@_spi(Experimental) import PKFoundationModelsProvider
#endif

/// Consumer verifying that @_spi(Experimental) imports unlock access to experimental
/// embedding surfaces, while ordinary imports (as in main.swift) cannot access them directly.
private func exerciseExperimentalEmbeddingSurfaces() async throws {
    // Protocol & Core types from PKContracts
    let budget = EmbeddingInputBudget(maxTextCount: 16, maxBytesPerText: 512, maxTotalBytes: 10_000)
    let space = EmbeddingSpace(provider: "test", model: "test-model", dimensions: 3, isNormalized: true)
    let embedding = Embedding(vector: [0.1, 0.2, 0.3], space: space)
    _ = try embedding.cosineSimilarity(to: embedding)

    let request = EmbeddingRequest(inputs: ["Hello world"], purpose: .query)
    let response = EmbeddingResponse(embeddings: [embedding], usage: EmbeddingUsage(inputTokens: 2))
    _ = (request, response, budget)

    let error = EmbeddingError.generationFailed
    _ = error.localizedDescription

    // Provider embedding clients
    let openAI = PKOpenAI.makeEmbeddingClient(apiKey: "test-key", model: "text-embedding-3-small")
    _ = openAI.inputBudget

    let ollama = PKOllama.makeEmbeddingClient(model: "nomic-embed-text", endpoint: "http://localhost:11434")
    _ = ollama.inputBudget

    #if canImport(NaturalLanguage)
    let apple = AppleNaturalLanguageEmbeddingClient()
    _ = apple.inputBudget
    #endif

    // Test support
    let mock = MockEmbeddingClient()
    _ = try await mock.embed(request)
    _ = EmbeddingClientConformanceSuite.self
}
