import Dependencies
import Foundation
@testable import PositronicKit
@testable import PKShared
import PKTestSupport
import Testing

@Suite("Context Manager Tests")
struct ContextManagerTests {
    @Test("Gather Context: Semantic Retrieval")
    func gatherContextSemanticRetrieval() async throws {
        let mockPersistence = MockPersistenceService()
        let mockEmbedding = MockEmbeddingService()
        let contextManager = try await TestDependencies()
            .withMocks(persistence: mockPersistence, embedding: mockEmbedding)
            .run {
                ContextManager(workspace: nil)
            }

        let expectedMemory = Memory.fixture(
            title: "SwiftUI Guide",
            content: "SwiftUI is declarative.",
            tags: ["swiftui"]
        )
        mockPersistence.memories = [expectedMemory]
        mockPersistence.searchResults = [(expectedMemory, 0.9)]

        let stream = await contextManager.gatherContext(for: "How to use SwiftUI?")
        let events = try await stream.collect()

        let context = events.compactMap { if case let .complete(data) = $0 { return data } else { return nil } }.first

        guard let context = context else {
            Issue.record("Context gathering failed to produce result")
            return
        }

        #expect(context.memories.count == 1)
        #expect(context.memories.first?.memory.id == expectedMemory.id)
        let similarity = context.memories.first?.similarity ?? 0
        #expect(abs(similarity - 0.9) < 0.001, "Expected similarity ~0.9, got \(similarity)")
        #expect(mockEmbedding.lastInput == "How to use SwiftUI?")
    }

    @Test("Gather Context: Uses History for Tags but Query for Embedding")
    func gatherContextUsesHistoryForTagsButQueryForEmbedding() async throws {
        let mockPersistence = MockPersistenceService()
        let mockEmbedding = MockEmbeddingService()
        let contextManager = try await TestDependencies()
            .withMocks(persistence: mockPersistence, embedding: mockEmbedding)
            .run {
                ContextManager(workspace: nil)
            }

        let memory = Memory.fixture(title: "Project Alpha", tags: ["alpha"])
        mockPersistence.memories = [memory]
        mockPersistence.searchResults = [(memory, 0.85)]

        let tagGenerator: @Sendable (String) async throws -> [String] = { text in
            if text.contains("Previous") { return ["alpha"] }
            return []
        }

        let history = [Message.fixture(content: "Previous message")]

        let stream = await contextManager.gatherContext(
            for: "Current query",
            history: history,
            tagGenerator: tagGenerator
        )
        let events = try await stream.collect()
        let context = events.compactMap { if case let .complete(data) = $0 { return data } else { return nil } }.first

        guard let context = context else {
            Issue.record("Context gathering failed to produce result")
            return
        }

        #expect(context.augmentedQuery?.contains("Previous message") == true)
        #expect(mockEmbedding.lastInput == "Current query")
    }

    @Test("Ranking Logic with Tag Boost")
    func rankingLogicWithTagBoost() async throws {
        let mockPersistence = MockPersistenceService()
        let mockEmbedding = MockEmbeddingService()
        let contextManager = try await TestDependencies()
            .withMocks(persistence: mockPersistence, embedding: mockEmbedding)
            .run {
                ContextManager(workspace: nil)
            }

        let memory1 = Memory.fixture(title: "Tag Match", tags: ["swift"])
        let memory2 = Memory.fixture(title: "Semantic Match")

        mockPersistence.memories = [memory1]
        mockPersistence.searchResults = [(memory2, 0.8)]

        let tagGenerator: @Sendable (String) async throws -> [String] = { _ in ["swift"] }

        let stream = await contextManager.gatherContext(
            for: "swift query",
            tagGenerator: tagGenerator
        )
        let events = try await stream.collect()
        let context = events.compactMap { if case let .complete(data) = $0 { return data } else { return nil } }.first

        guard let context = context else {
            Issue.record("Context gathering failed to produce result")
            return
        }

        #expect(context.memories.count == 2)
        #expect(context.memories.first?.memory.title == "Semantic Match")

        let tagMatch = context.memories.last
        #expect(tagMatch?.memory.title == "Tag Match")
        let tagSimilarity = tagMatch?.similarity ?? 0
        #expect(abs(tagSimilarity - 0.5) < 0.001, "Expected similarity ~0.5, got \(tagSimilarity)") // 0.0 base + 0.5 boost
    }

    @Test("Filesystem Notes Retrieval")
    func filesystemNotesRetrieval() async throws {
        let mockPersistence = MockPersistenceService()
        let mockEmbedding = MockEmbeddingService()

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let notesDir = tempURL.appendingPathComponent("Notes", isDirectory: true)
        try FileManager.default.createDirectory(at: notesDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let noteContent = """
        _Description: FS Note Description_

        Content from filesystem.
        """
        try noteContent.write(to: notesDir.appendingPathComponent("FSNote.md"), atomically: true, encoding: .utf8)

        let ref = WorkspaceReference.fixture(
            uri: WorkspaceURI(host: "pk-server", path: tempURL.path),
            rootPath: tempURL.path
        )
        let workspace = try MockLocalWorkspace(reference: ref)

        let manager = try await TestDependencies()
            .withMocks(persistence: mockPersistence, embedding: mockEmbedding)
            .run {
                ContextManager(workspace: workspace)
            }

        let stream = await manager.gatherContext(for: "some query")
        let events = try await stream.collect()
        let context = events.compactMap { if case let .complete(data) = $0 { return data } else { return nil } }.first

        guard let context = context else {
            Issue.record("Context gathering failed to produce result")
            return
        }

        #expect(context.notes.count == 1)
        let note = context.notes.first
        #expect(note?.name == "FSNote")
        #expect(note?.source == "Notes/FSNote.md")
        #expect(note?.content == noteContent)
    }

    @Test("Gather Context: Error Propagation")
    func gatherContextErrorPropagation() async throws {
        struct FailingWorkspace: WorkspaceProtocol {
            var id: UUID = UUID()
            var reference: WorkspaceReference = .fixture()
            func listTools() async throws -> [ToolReference] { [] }
            func executeTool(id: String, parameters: [String: AnyCodable]) async throws -> ToolResult {
                throw WorkspaceError.toolExecutionNotSupported
            }
            func listFiles(path: String) async throws -> [String] {
                throw WorkspaceError.connectionFailed
            }
            func readFile(path: String) async throws -> String { "" }
            func writeFile(path: String, content: String) async throws {}
            func deleteFile(path: String) async throws {}
            func healthCheck() async -> Bool { false }
        }

        let mockPersistence = MockPersistenceService()
        let mockEmbedding = MockEmbeddingService()
        let workspace = FailingWorkspace()

        let manager = try await TestDependencies()
            .withMocks(persistence: mockPersistence, embedding: mockEmbedding)
            .run {
                ContextManager(workspace: workspace)
            }

        let stream = await manager.gatherContext(for: "some query")
        
        await #expect(throws: Error.self) {
            for try await _ in stream {}
        }
    }
}
