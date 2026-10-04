import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
import Logging
import PKContracts
import PKUtilities

/// Wire request body for `POST /v1/embeddings`.
struct OpenAIEmbeddingRequestBody: Encodable {
    let model: String
    let input: [String]
    let dimensions: Int?
    let encodingFormat: String

    enum CodingKeys: String, CodingKey {
        case model
        case input
        case dimensions
        case encodingFormat = "encoding_format"
    }
}

/// Wire response body for `POST /v1/embeddings`.
struct OpenAIEmbeddingResponseBody: Decodable {
    struct Item: Decodable {
        let index: Int
        let embedding: [Float]
    }

    struct Usage: Decodable {
        let promptTokens: Int?

        enum CodingKeys: String, CodingKey {
            case promptTokens = "prompt_tokens"
        }
    }

    let data: [Item]
    let usage: Usage?
}

/// `EmbeddingClientProtocol` adapter over OpenAI's `/v1/embeddings` endpoint.
///
/// The adapter validates the request budget before any network I/O, sorts the response by the
/// provider's `index` field, and stamps every embedding with an `EmbeddingSpace` whose
/// provider is `"openai"`, whose model is the requested model, and whose dimensions come from
/// the returned vector.
public actor OpenAIEmbeddingClient: EmbeddingClientProtocol {
    /// Documented OpenAI embeddings request limits, expressed in UTF-8 bytes at roughly four
    /// bytes per token: 2048 inputs, 8191 tokens per input, and 300 000 tokens per request.
    public static let defaultInputBudget = EmbeddingInputBudget(
        maxTextCount: 2_048,
        maxBytesPerText: 32_764,
        maxTotalBytes: 1_200_000
    )

    public nonisolated let inputBudget: EmbeddingInputBudget

    private let apiKey: String
    private let modelName: String
    private let host: String
    private let port: Int
    private let scheme: String
    private let timeoutInterval: TimeInterval
    private let maxRetries: Int
    private let transport: any ProviderHTTPTransport
    private let logger = Logger.module(named: "openai-embedding-client")

    /// Creates a client that talks to the given OpenAI-compatible endpoint over `URLSession`.
    ///
    /// - Parameters:
    ///   - apiKey: Sent as the bearer token on every request.
    ///   - modelName: The embedding model to request, for example `"text-embedding-3-small"`.
    ///   - host: The API host, overridable for self-hosted or proxy endpoints.
    ///   - port: The API port; omitted from the request URL when it is the scheme's default.
    ///   - scheme: The URL scheme (`https` or `http`).
    ///   - timeoutInterval: Per-request timeout, in seconds.
    ///   - maxRetries: Retry attempts for transient transport failures.
    ///   - inputBudget: The request budget enforced before I/O.
    public init(
        apiKey: String,
        modelName: String = "text-embedding-3-small",
        host: String = "api.openai.com",
        port: Int = 443,
        scheme: String = "https",
        timeoutInterval: TimeInterval = 60.0,
        maxRetries: Int = 3,
        inputBudget: EmbeddingInputBudget = OpenAIEmbeddingClient.defaultInputBudget
    ) {
        self.init(
            apiKey: apiKey,
            modelName: modelName,
            host: host,
            port: port,
            scheme: scheme,
            timeoutInterval: timeoutInterval,
            maxRetries: maxRetries,
            inputBudget: inputBudget,
            transport: URLSessionProviderHTTPTransport(timeoutIntervalForRequest: timeoutInterval)
        )
    }

    package init(
        apiKey: String,
        modelName: String = "text-embedding-3-small",
        host: String = "api.openai.com",
        port: Int = 443,
        scheme: String = "https",
        timeoutInterval: TimeInterval = 60.0,
        maxRetries: Int = 3,
        inputBudget: EmbeddingInputBudget = OpenAIEmbeddingClient.defaultInputBudget,
        transport: any ProviderHTTPTransport
    ) {
        self.apiKey = apiKey
        self.modelName = modelName
        self.host = host
        self.port = port
        self.scheme = scheme
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
                OpenAIEmbeddingResponseBody.self,
                for: networkRequest,
                transport: self.transport,
                provider: "OpenAI"
            )
        }

        guard body.data.count == request.inputs.count else {
            throw EmbeddingError.responseCountMismatch(expected: request.inputs.count, actual: body.data.count)
        }

        let embeddings = body.data.sorted { $0.index < $1.index }.map { item in
            Embedding(
                vector: item.embedding,
                space: EmbeddingSpace(
                    provider: "openai",
                    model: modelName,
                    dimensions: item.embedding.count,
                    isNormalized: true
                )
            )
        }

        let usage = body.usage?.promptTokens.map { EmbeddingUsage(inputTokens: $0) }
        return EmbeddingResponse(embeddings: embeddings, usage: usage)
    }

    private func makeRequest(_ request: EmbeddingRequest) throws -> URLRequest {
        guard let url = embeddingsURL else {
            throw LLMServiceError.invalidConfiguration
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = timeoutInterval
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        urlRequest.httpBody = try encoder.encode(OpenAIEmbeddingRequestBody(
            model: modelName,
            input: request.inputs,
            dimensions: request.dimensions,
            encodingFormat: "float"
        ))
        return urlRequest
    }

    private var embeddingsURL: URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        if !Self.isDefaultPort(scheme: scheme, port: port) {
            components.port = port
        }
        components.path = "/v1/embeddings"
        return components.url
    }

    private static func isDefaultPort(scheme: String, port: Int) -> Bool {
        (scheme == "https" && port == 443) || (scheme == "http" && port == 80) || port == 0
    }
}
