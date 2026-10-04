import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
import Logging
import PKContracts
import PKUtilities

/// Wire request body for `POST /api/embed`.
struct OllamaEmbedRequestBody: Encodable {
    let model: String
    let input: [String]
}

/// Wire response body for `POST /api/embed`.
struct OllamaEmbedResponseBody: Decodable {
    let model: String?
    let embeddings: [[Float]]
    let promptEvalCount: Int?

    enum CodingKeys: String, CodingKey {
        case model
        case embeddings
        case promptEvalCount = "prompt_eval_count"
    }
}

/// `EmbeddingClientProtocol` adapter over Ollama's `/api/embed` endpoint.
///
/// Ollama's normalization depends on the pulled model, so every embedding reports
/// `isNormalized: false` unless a caller verifies otherwise. The adapter declares the default
/// budget and rejects an oversized request before any network I/O.
public actor OllamaEmbeddingClient: EmbeddingClientProtocol {
    public nonisolated let inputBudget: EmbeddingInputBudget

    private let endpoint: OllamaEndpoint
    private let modelName: String
    private let timeoutInterval: TimeInterval
    private let maxRetries: Int
    private let transport: any ProviderHTTPTransport
    private let logger = Logger.module(named: "ollama-embedding-client")

    /// Creates a client that talks to the given Ollama server over `URLSession`.
    ///
    /// - Parameters:
    ///   - endpoint: The base URL of the Ollama server, for example `http://localhost:11434`.
    ///   - modelName: The embedding model to request, for example `"nomic-embed-text"`.
    ///   - timeoutInterval: Per-request timeout, in seconds.
    ///   - maxRetries: Retry attempts for transient transport failures.
    ///   - inputBudget: The request budget enforced before I/O.
    public init(
        endpoint: String = "http://localhost:11434",
        modelName: String,
        timeoutInterval: TimeInterval = 120.0,
        maxRetries: Int = 3,
        inputBudget: EmbeddingInputBudget = .default
    ) {
        self.init(
            endpoint: endpoint,
            modelName: modelName,
            timeoutInterval: timeoutInterval,
            maxRetries: maxRetries,
            inputBudget: inputBudget,
            transport: URLSessionProviderHTTPTransport(
                timeoutIntervalForRequest: timeoutInterval,
                timeoutIntervalForResource: timeoutInterval * 5,
                waitsForConnectivity: true
            )
        )
    }

    package init(
        endpoint: String = "http://localhost:11434",
        modelName: String,
        timeoutInterval: TimeInterval = 120.0,
        maxRetries: Int = 3,
        inputBudget: EmbeddingInputBudget = .default,
        transport: any ProviderHTTPTransport
    ) {
        self.endpoint = OllamaEndpoint(rawValue: endpoint)
        self.modelName = modelName
        self.timeoutInterval = timeoutInterval
        self.maxRetries = maxRetries
        self.inputBudget = inputBudget
        self.transport = transport
    }

    public func embed(_ request: EmbeddingRequest) async throws -> EmbeddingResponse {
        try inputBudget.validate(request.inputs)

        let networkRequest = try makeRequest(request)
        let maxRetries = self.maxRetries

        let body = try await RetryPolicy.retry(maxRetries: maxRetries) {
            try await HTTPHelpers.fetchDecodable(
                OllamaEmbedResponseBody.self,
                for: networkRequest,
                transport: self.transport,
                provider: "Ollama"
            )
        }

        guard body.embeddings.count == request.inputs.count else {
            throw EmbeddingError.responseCountMismatch(expected: request.inputs.count, actual: body.embeddings.count)
        }

        let embeddings = body.embeddings.map { vector in
            Embedding(
                vector: vector,
                space: EmbeddingSpace(
                    provider: "ollama",
                    model: self.modelName,
                    dimensions: vector.count,
                    isNormalized: false
                )
            )
        }

        let usage = body.promptEvalCount.map { EmbeddingUsage(inputTokens: $0) }
        return EmbeddingResponse(embeddings: embeddings, usage: usage)
    }

    private func makeRequest(_ request: EmbeddingRequest) throws -> URLRequest {
        guard let url = endpoint.embedURL else {
            throw LLMServiceError.invalidConfiguration
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = timeoutInterval
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        urlRequest.httpBody = try encoder.encode(OllamaEmbedRequestBody(model: modelName, input: request.inputs))
        return urlRequest
    }
}
