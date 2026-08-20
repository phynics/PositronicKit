import Foundation
@testable import PKContracts
import PKUtilities
@testable import PositronicKit
import Testing

/// Coverage for `NoOpEmbeddingService` — the zero-vector embedding stub used when
/// embedding-based search is disabled. Its batch method was previously untested.
@Suite("NoOpEmbeddingService")
struct NoOpEmbeddingServiceTests {

    @Test("generateEmbedding returns an empty vector")
    func singleEmbeddingIsEmpty() async throws {
        let service = NoOpEmbeddingService()
        let embedding = try await service.generateEmbedding(for: "anything")
        #expect(embedding.isEmpty)
    }

    @Test("generateEmbeddings returns one empty vector per input text")
    func batchEmbeddingsAreEmpty() async throws {
        let service = NoOpEmbeddingService()
        let embeddings = try await service.generateEmbeddings(for: ["a", "b", "c"])
        #expect(embeddings.count == 3)
        #expect(embeddings.allSatisfy { $0.isEmpty })
    }

    @Test("generateEmbeddings returns empty for an empty input")
    func emptyBatchReturnsEmpty() async throws {
        let service = NoOpEmbeddingService()
        let embeddings = try await service.generateEmbeddings(for: [])
        #expect(embeddings.isEmpty)
    }
}

/// Coverage for `TurnRequest.description` — the debug summary used in logs.
/// The computed `description` was previously untested.
@Suite("TurnRequest.description")
struct TurnRequestDescriptionTests {

    @Test("canonical thread identifier is stored and described")
    func canonicalThreadIdentifier() {
        let threadID = UUID()
        let request = TurnRequest(
            threadID: threadID,
            message: "Hello, world!"
        )

        #expect(request.threadID == threadID)
        #expect(request.description.contains(threadID.uuidString))
    }

    @Test("description includes the thread id but redacts the message")
    func includesThreadAndRedactsMessage() {
        let threadID = UUID()
        let request = TurnRequest(
            threadID: threadID,
            message: "Hello, world!",
            maxModelRounds: 3
        )
        let desc = request.description

        #expect(desc.contains(threadID.uuidString))
        #expect(desc.contains("message: <redacted>"))
        #expect(desc.contains("maxModelRounds: 3"))
        #expect(desc.contains("tools: 0"))
    }

    @Test("description reports nil for optional fields when omitted")
    func nilOptionalsReportedAsNil() {
        let request = TurnRequest(
            threadID: UUID(),
            message: "ping"
        )
        let desc = request.description

        #expect(desc.contains("requestID: nil"))
        #expect(desc.contains("systemInstructions: nil"))
        #expect(desc.contains("agentID: nil"))
        #expect(desc.contains("generationParameters: nil"))
        #expect(desc.contains("structuredOutput: nil"))
        #expect(desc.contains("promptAssemblyLogger: nil"))
    }

    @Test("description reports set values for optional fields")
    func setOptionalsReported() {
        let requestId = UUID()
        let agentId = UUID()
        let request = TurnRequest(
            threadID: UUID(),
            requestID: requestId,
            message: "hi",
            systemInstructions: "Be helpful.",
            agentID: agentId,
            maxModelRounds: 10
        )
        let desc = request.description

        #expect(desc.contains(requestId.uuidString))
        #expect(desc.contains("set(11 chars)"))
        #expect(desc.contains(agentId.uuidString))
        #expect(desc.contains("maxModelRounds: 10"))
    }

    @Test("description counts tools and tool outputs")
    func countsToolsAndOutputs() {
        let request = TurnRequest(
            threadID: UUID(),
            message: "run",
            toolOutputs: [
                ToolOutputSubmission(toolCallID: "call_1", output: "result"),
            ]
        )
        let desc = request.description

        #expect(desc.contains("toolOutputs: 1"))
    }
}
