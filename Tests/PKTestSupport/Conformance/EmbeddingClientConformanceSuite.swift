import Foundation
import PKContracts
internal import Testing

/// Shared conformance checks for ``EmbeddingClientProtocol`` implementations.
///
/// A client test runs ``run(client:inputs:)`` against a client backed by scripted or local
/// responses. The suite checks input-order preservation, that the client rejects an oversized
/// request before I/O, that a wrong response count surfaces as
/// ``EmbeddingError/responseCountMismatch(expected:actual:)``, and that
/// ``EmbeddingClientProtocol/embedDocuments(_:)`` respects the declared batch boundaries.
public enum EmbeddingClientConformanceSuite {
    /// Runs the conformance checks for a client that returns deterministic embeddings.
    public static func run(
        client: any EmbeddingClientProtocol,
        inputs: [String]
    ) async throws {
        try await verifyOrderPreservation(client: client, inputs: inputs)
        try await verifyBudgetRejectionBeforeIO(client: client)
        try await verifyResponseCountMismatch()
        try await verifyBatchingBoundaries()
    }

    /// Runs the conformance checks and compares the returned vectors against a known fixture.
    public static func run(
        client: any EmbeddingClientProtocol,
        inputs: [String],
        expectedVectors: [[Float]]
    ) async throws {
        let embeddings = try await client.embedDocuments(inputs)
        try #require(embeddings.map(\.vector) == expectedVectors, "embedding-client.golden-vectors")
        try await verifyBudgetRejectionBeforeIO(client: client)
        try await verifyResponseCountMismatch()
        try await verifyBatchingBoundaries()
    }

    private static func verifyOrderPreservation(
        client: any EmbeddingClientProtocol,
        inputs: [String]
    ) async throws {
        guard !inputs.isEmpty else { return }
        let forward = try await client.embedDocuments(inputs)
        try #require(forward.count == inputs.count, "embedding-client.order.count")
        let reversed = try await client.embedDocuments(inputs.reversed())
        try #require(forward == Array(reversed.reversed()), "embedding-client.order.vectors")
    }

    private static func verifyBudgetRejectionBeforeIO(client: any EmbeddingClientProtocol) async throws {
        let budget = client.inputBudget
        guard budget.maxBytesPerText < Int.max else { return }
        let oversized = String(repeating: "a", count: budget.maxBytesPerText + 1)

        do {
            _ = try await client.embed(EmbeddingRequest(inputs: [oversized], purpose: .document))
            Issue.record("embedding-client.budget.rejected: client admitted an oversized request")
        } catch let error as EmbeddingError {
            guard case .perTextByteLimitExceeded = error else {
                Issue.record("embedding-client.budget.rejected: unexpected error \(error)")
                return
            }
        }
    }

    private static func verifyResponseCountMismatch() async throws {
        let client = MockEmbeddingClient()
        client.responseCountOverride = 0

        do {
            _ = try await client.embedDocuments(["count-mismatch"])
            Issue.record("embedding-client.count-mismatch: client accepted a short response")
        } catch let error as EmbeddingError {
            guard case let .responseCountMismatch(expected, actual) = error else {
                Issue.record("embedding-client.count-mismatch: unexpected error \(error)")
                return
            }
            try #require(expected == 1, "embedding-client.count-mismatch.expected")
            try #require(actual == 0, "embedding-client.count-mismatch.actual")
        }
    }

    private static func verifyBatchingBoundaries() async throws {
        let budget = EmbeddingInputBudget(maxTextCount: 2, maxBytesPerText: 100, maxTotalBytes: 5)
        let client = MockEmbeddingClient(inputBudget: budget)
        let texts = ["aa", "bb", "cc", "dd", "ee"]

        let embeddings = try await client.embedDocuments(texts)
        try #require(embeddings.count == texts.count, "embedding-client.batching.count")
        try #require(client.recordedRequests.count == 3, "embedding-client.batching.requests")
        try #require(client.recordedRequests.allSatisfy { $0.inputs.count <= budget.maxTextCount }, "embedding-client.batching.size")
    }
}
