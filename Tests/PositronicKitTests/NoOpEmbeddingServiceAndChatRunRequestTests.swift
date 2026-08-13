import Foundation
@testable import PKShared
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

/// Coverage for `ChatRunRequest.description` — the debug summary used in logs.
/// The computed `description` was previously untested.
@Suite("ChatRunRequest.description")
struct ChatRunRequestDescriptionTests {

    @Test("canonical thread identifier is stored and described")
    func canonicalThreadIdentifier() {
        let threadID = UUID()
        let request = ChatRunRequest(
            threadID: threadID,
            message: "Hello, world!"
        )

        #expect(request.threadID == threadID)
        #expect(request.description.contains(threadID.uuidString))
    }

    @Test("description includes the timeline id but redacts the message")
    func includesTimelineAndRedactsMessage() {
        let timelineId = UUID()
        let request = ChatRunRequest(
            timelineID: timelineId,
            message: "Hello, world!",
            maxTurns: 3
        )
        let desc = request.description

        #expect(desc.contains(timelineId.uuidString))
        #expect(desc.contains("message: <redacted>"))
        #expect(desc.contains("maxTurns: 3"))
        #expect(desc.contains("tools: 0"))
    }

    @Test("description reports nil for optional fields when omitted")
    func nilOptionalsReportedAsNil() {
        let request = ChatRunRequest(
            timelineID: UUID(),
            message: "ping"
        )
        let desc = request.description

        #expect(desc.contains("sendID: nil"))
        #expect(desc.contains("systemInstructions: nil"))
        #expect(desc.contains("agentInstanceID: nil"))
        #expect(desc.contains("generationParameters: nil"))
        #expect(desc.contains("structuredOutput: nil"))
        #expect(desc.contains("promptAssemblyLogger: nil"))
    }

    @Test("description reports set values for optional fields")
    func setOptionalsReported() {
        let sendId = UUID()
        let agentId = UUID()
        let request = ChatRunRequest(
            timelineID: UUID(),
            sendID: sendId,
            message: "hi",
            systemInstructions: "Be helpful.",
            agentInstanceID: agentId,
            maxTurns: 10
        )
        let desc = request.description

        #expect(desc.contains(sendId.uuidString))
        #expect(desc.contains("set(11 chars)"))
        #expect(desc.contains(agentId.uuidString))
        #expect(desc.contains("maxTurns: 10"))
    }

    @Test("description counts tools and tool outputs")
    func countsToolsAndOutputs() {
        let request = ChatRunRequest(
            timelineID: UUID(),
            message: "run",
            toolOutputs: [
                ToolOutputSubmission(toolCallID: "call_1", output: "result"),
            ]
        )
        let desc = request.description

        #expect(desc.contains("toolOutputs: 1"))
    }
}
