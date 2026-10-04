import Foundation
import PKContracts
import Synchronization

/// Deterministic in-memory ``EmbeddingClientProtocol`` test double.
///
/// Vectors are derived from a stable hash of each input, so the same text always produces the
/// same vector and different texts produce different vectors. The client records every admitted
/// request, exposes a configurable ``space`` and ``inputBudget``, and can be scripted to throw or
/// to return the wrong number of embeddings so callers can exercise failure paths.
public final class MockEmbeddingClient: EmbeddingClientProtocol, Sendable {
    private struct State: Sendable {
        var space: EmbeddingSpace
        var requests: [EmbeddingRequest] = []
        var responseCountOverride: Int?
        var errorToThrow: EmbeddingError?
    }

    private let state: Mutex<State>

    /// The budget used to validate inputs before recording or returning a result.
    public let inputBudget: EmbeddingInputBudget

    public init(
        space: EmbeddingSpace = EmbeddingSpace(
            provider: "mock",
            model: "mock-embedding",
            dimensions: 8,
            isNormalized: true
        ),
        inputBudget: EmbeddingInputBudget = .default
    ) {
        self.state = Mutex(State(space: space))
        self.inputBudget = inputBudget
    }

    /// The vector space stamped on every returned embedding.
    public var space: EmbeddingSpace {
        get { state.withLock { $0.space } }
        set { state.withLock { $0.space = newValue } }
    }

    /// Every request admitted by ``embed(_:)``, in call order.
    public var recordedRequests: [EmbeddingRequest] {
        state.withLock { $0.requests }
    }

    /// When set, ``embed(_:)`` returns this many embeddings instead of one per input.
    public var responseCountOverride: Int? {
        get { state.withLock { $0.responseCountOverride } }
        set { state.withLock { $0.responseCountOverride = newValue } }
    }

    /// When set, ``embed(_:)`` throws this error instead of returning embeddings.
    public var errorToThrow: EmbeddingError? {
        get { state.withLock { $0.errorToThrow } }
        set { state.withLock { $0.errorToThrow = newValue } }
    }

    public func embed(_ request: EmbeddingRequest) async throws -> EmbeddingResponse {
        // Reject before recording so a budget failure never looks like I/O happened.
        try inputBudget.validate(request.inputs)

        let snapshot = state.withLock { state -> State in
            state.requests.append(request)
            return state
        }

        if let errorToThrow = snapshot.errorToThrow {
            throw errorToThrow
        }

        let count = snapshot.responseCountOverride ?? request.inputs.count
        let embeddings = (0 ..< max(0, count)).map { index in
            let text = index < request.inputs.count ? request.inputs[index] : "mock-\(index)"
            return Self.makeEmbedding(for: text, space: snapshot.space)
        }
        let inputTokens = request.inputs.reduce(0) { $0 + max(1, $1.utf8.count / 4) }
        return EmbeddingResponse(embeddings: embeddings, usage: EmbeddingUsage(inputTokens: inputTokens))
    }

    private static func makeEmbedding(for text: String, space: EmbeddingSpace) -> Embedding {
        let dimensions = max(0, space.dimensions)
        guard dimensions > 0 else {
            return Embedding(vector: [], space: space)
        }

        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }

        var vector: [Float] = []
        vector.reserveCapacity(dimensions)
        for _ in 0 ..< dimensions {
            hash = hash &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let unit = Float(hash >> 40) / Float(1 << 24)
            vector.append(unit * 2 - 1)
        }

        if space.isNormalized {
            let magnitude = vector.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
            if magnitude > 0, magnitude.isFinite {
                vector = vector.map { $0 / magnitude }
            }
        }

        return Embedding(vector: vector, space: space)
    }
}
