import Foundation
import Logging
@testable import PKContracts
import PKUtilities
import PKTestSupport
@testable import PositronicKit
import Testing

@Suite("Turn Briefing Builder Tests")
struct TurnBriefingBuilderTests {
    private func makeTurnBriefingBuilder(
        workspace: (any Workspace)? = nil,
        persistence: MockPersistenceService
    ) -> TurnBriefingBuilder {
        let stages: [any PipelineStage<ContextPipelineContext, ContextGatheringEvent>] = [
            QueryAugmentationStage(),
            MemoryRetrievalStage(memoryStore: persistence),
            NoteDiscoveryStage(workspace: workspace),
            ContextAssemblyStage(logger: Logger(label: "test.context-assembly")),
        ]
        return TurnBriefingBuilder(workspace: workspace, pipeline: Pipeline(stages: stages))
    }

    @Test("Gather Context: Tag-based Retrieval")
    func gatherContextTagRetrieval() async throws {
        let mockPersistence = MockPersistenceService()
        let turnBriefingBuilder = makeTurnBriefingBuilder(persistence: mockPersistence)

        let expectedMemory = Memory.fixture(
            title: "SwiftUI Guide",
            content: "SwiftUI is declarative.",
            tags: ["swiftui"]
        )
        mockPersistence.memories = [expectedMemory]

        let tagGenerator: @Sendable (String) async throws -> [String] = { _ in ["swiftui"] }

        let stream = await turnBriefingBuilder.gatherContext(for: "How to use SwiftUI?", tagGenerator: tagGenerator)
        let events = try await stream.collect()

        let context = events.compactMap { if case let .complete(data) = $0 { return data } else { return nil } }.first

        guard let context = context else {
            Issue.record("Context gathering failed to produce result")
            return
        }

        #expect(context.memories.count == 1)
        #expect(context.memories.first?.id == expectedMemory.id)
    }

    @Test("Gather Context: Uses History for Tags")
    func gatherContextUsesHistoryForTags() async throws {
        let mockPersistence = MockPersistenceService()
        let turnBriefingBuilder = makeTurnBriefingBuilder(persistence: mockPersistence)

        let memory = Memory.fixture(title: "Project Alpha", tags: ["alpha"])
        mockPersistence.memories = [memory]

        let tagGenerator: @Sendable (String) async throws -> [String] = { text in
            if text.contains("Previous") { return ["alpha"] }
            return []
        }

        let history = [Message.fixture(content: "Previous message")]

        let stream = await turnBriefingBuilder.gatherContext(
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
    }

    @Test("Empty memory store skips LLM tag generation")
    func emptyMemoryStoreSkipsLLMTagGeneration() async throws {
        let mockPersistence = MockPersistenceService()
        let turnBriefingBuilder = makeTurnBriefingBuilder(persistence: mockPersistence)
        let tagProbe = TagProbe()
        let tagGenerator: @Sendable (String) async throws -> [String] = { _ in
            await tagProbe.recordCall()
            return ["swift"]
        }

        let stream = await turnBriefingBuilder.gatherContext(
            for: "fresh thread",
            tagGenerator: tagGenerator
        )
        let events = try await stream.collect()
        let progresses = events.compactMap { event -> Message.ContextGatheringProgress? in
            if case let .progress(progress) = event { return progress }
            return nil
        }
        let context = events.compactMap { if case let .complete(data) = $0 { return data } else { return nil } }.first

        #expect(context != nil)
        #expect(progresses == [.augmenting, .discoveringNotes, .complete])
        #expect(await tagProbe.calls == 0)
    }

    @Test("Ranking Logic with Tag Boost")
    func rankingLogicWithTagBoost() async throws {
        let mockPersistence = MockPersistenceService()
        let turnBriefingBuilder = makeTurnBriefingBuilder(persistence: mockPersistence)

        let memory1 = Memory.fixture(title: "Tag Match", tags: ["swift"])

        mockPersistence.memories = [memory1]

        let tagGenerator: @Sendable (String) async throws -> [String] = { _ in ["swift"] }

        let stream = await turnBriefingBuilder.gatherContext(
            for: "swift query",
            tagGenerator: tagGenerator
        )
        let events = try await stream.collect()
        let context = events.compactMap { if case let .complete(data) = $0 { return data } else { return nil } }.first

        guard let context = context else {
            Issue.record("Context gathering failed to produce result")
            return
        }

        #expect(context.memories.count == 1)
        #expect(context.memories.first?.title == "Tag Match")
    }

    @Test("Filesystem Notes Retrieval")
    func filesystemNotesRetrieval() async throws {
        let mockPersistence = MockPersistenceService()

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
            uri: WorkspaceURI(host: "pk-runtime", path: tempURL.path),
            rootPath: tempURL.path
        )
        let workspace = try MockLocalWorkspace(reference: ref)

        let manager = makeTurnBriefingBuilder(
            workspace: workspace,
            persistence: mockPersistence
        )

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

    @Test("Note discovery limits total files and bytes deterministically")
    func noteDiscoveryLimitsTotalFilesAndBytes() async throws {
        let workspace = NoteDiscoveryProbeWorkspace(
            paths: ["Notes/z.md", "Notes/b.md", "Notes/a.md", "Notes/ignored.txt"],
            contents: [
                "Notes/z.md": "z",
                "Notes/b.md": "bbbb",
                "Notes/a.md": "aaaa",
                "Notes/ignored.txt": "ignored",
            ]
        )
        let stage = NoteDiscoveryStage(workspace: workspace, maxFileCount: 2, maxTotalBytes: 6)
        let context = ContextPipelineContext(
            query: "query",
            history: [],
            limit: 0,
            tagGenerator: nil,
            startTime: 0
        )

        let stream = try await stage.process(context)
        for try await _ in stream {}

        let notes = await context.notes
        #expect(notes.map(\.source) == ["Notes/a.md", "Notes/b.md"])
        #expect(notes.map(\.content) == ["aaaa", "bb"])
        #expect(await workspace.readPaths == ["Notes/a.md", "Notes/b.md"])
    }

    @Test("Gather Context: Error Propagation")
    func gatherContextErrorPropagation() async throws {
        struct FailingWorkspace: Workspace {
            var id: UUID = .init()
            var reference: WorkspaceReference = .fixture()
            func listTools() async throws -> [ToolReference] {
                []
            }

            func executeTool(id _: String, parameters _: [String: AnyCodable]) async throws -> ToolResult {
                throw WorkspaceError.toolExecutionNotSupported
            }

            func listFiles(path _: String) async throws -> [String] {
                throw WorkspaceError.connectionFailed
            }

            func readFile(path _: String) async throws -> String {
                ""
            }

            func writeFile(path _: String, content _: String) async throws {}
            func deleteFile(path _: String) async throws {}
            func healthCheck() async -> Bool {
                false
            }
        }

        let mockPersistence = MockPersistenceService()
        let workspace = FailingWorkspace()

        let manager = makeTurnBriefingBuilder(
            workspace: workspace,
            persistence: mockPersistence
        )

        let stream = await manager.gatherContext(for: "some query")

        await #expect(throws: Error.self) {
            for try await _ in stream {}
        }
    }
}

private actor TagProbe {
    private(set) var calls = 0

    func recordCall() {
        calls += 1
    }
}

private actor NoteDiscoveryProbeWorkspace: Workspace {
    nonisolated let id: UUID
    nonisolated let reference: WorkspaceReference
    private let paths: [String]
    private let contents: [String: String]
    private(set) var readPaths: [String] = []

    init(paths: [String], contents: [String: String]) {
        let reference = WorkspaceReference.fixture()
        id = reference.id
        self.reference = reference
        self.paths = paths
        self.contents = contents
    }

    func listTools() async throws -> [ToolReference] {
        []
    }

    func executeTool(id _: String, parameters _: [String: AnyCodable]) async throws -> ToolResult {
        throw WorkspaceError.toolExecutionNotSupported
    }

    func readFile(path: String) async throws -> String {
        readPaths.append(path)
        guard let content = contents[path] else {
            throw WorkspaceError.workspaceNotFound
        }
        return content
    }

    func writeFile(path _: String, content _: String) async throws {}

    func listFiles(path _: String) async throws -> [String] {
        paths
    }

    func deleteFile(path _: String) async throws {}

    func healthCheck() async -> Bool {
        true
    }
}
