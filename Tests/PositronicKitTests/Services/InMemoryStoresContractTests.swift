import Foundation
@testable import PKContracts
import PKUtilities
@testable import PositronicKit
import Testing

/// Contract tests for the in-memory persistence stores.
///
/// These `actor`-backed stores are the shipping reference conformers for their respective
/// protocols and are reused by downstream consumers (Monad, Yakamoz) during development and
/// testing. They previously had near-zero direct coverage — most exercise came transitively
/// through higher-level facade tests, which left CRUD edge cases (not-found, update, delete,
/// origin/primary resolution) unverified. These tests pin the contract directly.
@Suite("In-memory stores")
struct InMemoryStoresContractTests {

    // MARK: - InMemoryToolPersistence

    @Suite("InMemoryToolPersistence")
    struct ToolPersistenceTests {
        private func makeWorkspace(
            id: UUID = UUID(),
            originId: UUID? = nil,
            location: WorkspaceReference.WorkspaceLocation = .runtime,
            uri: WorkspaceURI = WorkspaceURI(host: "localhost", path: "/tmp/ws")
        ) -> WorkspaceReference {
            WorkspaceReference(
                id: id, uri: uri, location: location, originID: originId, tools: []
            )
        }

        @Test("addToolToWorkspace appends to an existing workspace")
        func addToolAppends() async throws {
            let store = InMemoryToolPersistence()
            let wsId = UUID()
            await store.replaceWorkspaces([makeWorkspace(id: wsId)])

            try await store.addToolToWorkspace(workspaceId: wsId, tool: .known("read_file"))
            try await store.addToolToWorkspace(workspaceId: wsId, tool: .known("list_dir"))

            let tools = try await store.fetchTools(forWorkspaces: [wsId])
            #expect(tools.count == 2)
            #expect(tools.map(\.toolID) == ["read_file", "list_dir"])
        }

        @Test("addToolToWorkspace throws when workspace is missing")
        func addToolMissingWorkspaceThrows() async throws {
            let store = InMemoryToolPersistence()

            await #expect(throws: ToolError.self) {
                try await store.addToolToWorkspace(workspaceId: UUID(), tool: .known("read_file"))
            }
        }

        @Test("syncTools replaces the entire tool set for a workspace")
        func syncToolsReplaces() async throws {
            let store = InMemoryToolPersistence()
            let wsId = UUID()
            await store.replaceWorkspaces([makeWorkspace(id: wsId)])
            try await store.addToolToWorkspace(workspaceId: wsId, tool: .known("old_tool"))

            try await store.syncTools(workspaceId: wsId, tools: [.known("a"), .known("b")])

            let tools = try await store.fetchTools(forWorkspaces: [wsId])
            #expect(tools.count == 2)
            #expect(tools.map(\.toolID) == ["a", "b"])
        }

        @Test("syncTools throws when workspace is missing")
        func syncToolsMissingWorkspaceThrows() async throws {
            let store = InMemoryToolPersistence()

            await #expect(throws: ToolError.self) {
                try await store.syncTools(workspaceId: UUID(), tools: [.known("a")])
            }
        }

        @Test("fetchTools unions tools across multiple workspaces")
        func fetchToolsUnionsAcrossWorkspaces() async throws {
            let store = InMemoryToolPersistence()
            let wsA = UUID(), wsB = UUID(), wsC = UUID()
            await store.replaceWorkspaces([
                makeWorkspace(id: wsA, originId: nil),
                makeWorkspace(id: wsB, originId: nil),
                makeWorkspace(id: wsC, originId: nil),
            ])
            try await store.addToolToWorkspace(workspaceId: wsA, tool: .known("a1"))
            try await store.addToolToWorkspace(workspaceId: wsB, tool: .known("b1"))
            try await store.addToolToWorkspace(workspaceId: wsC, tool: .known("c1"))

            let tools = try await store.fetchTools(forWorkspaces: [wsA, wsC])
            #expect(tools.count == 2)
            #expect(Set(tools.map(\.toolID)) == Set(["a1", "c1"]))
        }

        @Test("fetchOriginTools returns tools for workspaces matching the origin")
        func fetchOriginToolsFiltersByOrigin() async throws {
            let store = InMemoryToolPersistence()
            let origin = UUID()
            let wsA = UUID(), wsB = UUID()
            await store.replaceWorkspaces([
                makeWorkspace(id: wsA, originId: origin),
                makeWorkspace(id: wsB, originId: nil),
            ])
            try await store.addToolToWorkspace(workspaceId: wsA, tool: .known("a"))
            try await store.addToolToWorkspace(workspaceId: wsB, tool: .known("b"))

            let originTools = try await store.fetchOriginTools(originId: origin)
            #expect(originTools.count == 1)
            #expect(originTools.first?.toolID == "a")
        }

        @Test("findWorkspaceId locates the workspace owning a tool")
        func findWorkspaceIdLocatesOwner() async throws {
            let store = InMemoryToolPersistence()
            let wsA = UUID(), wsB = UUID()
            await store.replaceWorkspaces([makeWorkspace(id: wsA), makeWorkspace(id: wsB)])
            try await store.addToolToWorkspace(workspaceId: wsA, tool: .known("a"))
            try await store.addToolToWorkspace(workspaceId: wsB, tool: .known("b"))

            let found = try await store.findWorkspaceId(forToolId: "b", in: [wsA, wsB])
            #expect(found == wsB)
        }

        @Test("findWorkspaceId returns nil for an unknown tool")
        func findWorkspaceIdUnknownReturnsNil() async throws {
            let store = InMemoryToolPersistence()
            let wsA = UUID()
            await store.replaceWorkspaces([makeWorkspace(id: wsA)])

            let found = try await store.findWorkspaceId(forToolId: "nope", in: [wsA])
            #expect(found == nil)
        }

        @Test("findWorkspaceId scopes the search to the provided workspace ids")
        func findWorkspaceIdScopedToProvidedIds() async throws {
            let store = InMemoryToolPersistence()
            let wsA = UUID(), wsB = UUID()
            await store.replaceWorkspaces([makeWorkspace(id: wsA), makeWorkspace(id: wsB)])
            try await store.addToolToWorkspace(workspaceId: wsB, tool: .known("b"))

            // Tool "b" exists in wsB, but wsB is not in the search set.
            let found = try await store.findWorkspaceId(forToolId: "b", in: [wsA])
            #expect(found == nil)
        }

        @Test("fetchToolSource returns 'Additional Workspace' for attached workspaces")
        func fetchToolSourceAttachedWorkspace() async throws {
            let store = InMemoryToolPersistence()
            let wsId = UUID()
            await store.replaceWorkspaces([
                makeWorkspace(id: wsId, location: .attached)
            ])
            try await store.addToolToWorkspace(workspaceId: wsId, tool: .known("t"))

            let source = try await store.fetchToolSource(
                toolId: "t", workspaceIds: [wsId], primaryWorkspaceId: UUID()
            )
            #expect(source == "Additional Workspace")
        }

        @Test("fetchToolSource returns 'Primary Workspace' for the primary workspace")
        func fetchToolSourcePrimaryWorkspace() async throws {
            let store = InMemoryToolPersistence()
            let wsId = UUID()
            await store.replaceWorkspaces([
                makeWorkspace(id: wsId, location: .runtimeThread)
            ])
            try await store.addToolToWorkspace(workspaceId: wsId, tool: .known("t"))

            let source = try await store.fetchToolSource(
                toolId: "t", workspaceIds: [wsId], primaryWorkspaceId: wsId
            )
            #expect(source == "Primary Workspace")
        }

        @Test("fetchToolSource returns a URI-based label for other runtime workspaces")
        func fetchToolSourceOtherRuntimeWorkspace() async throws {
            let store = InMemoryToolPersistence()
            let wsId = UUID()
            let uri = WorkspaceURI(host: "localhost", path: "/projects/extra")
            await store.replaceWorkspaces([
                makeWorkspace(id: wsId, location: .runtimeThread, uri: uri)
            ])
            try await store.addToolToWorkspace(workspaceId: wsId, tool: .known("t"))

            let source = try await store.fetchToolSource(
                toolId: "t", workspaceIds: [wsId], primaryWorkspaceId: UUID()
            )
            #expect(source?.hasPrefix("Workspace:") == true)
            #expect(source?.contains("/projects/extra") == true)
        }

        @Test("fetchToolSource returns nil for an unknown tool")
        func fetchToolSourceUnknownReturnsNil() async throws {
            let store = InMemoryToolPersistence()
            let wsId = UUID()
            await store.replaceWorkspaces([makeWorkspace(id: wsId)])

            let source = try await store.fetchToolSource(
                toolId: "ghost", workspaceIds: [wsId], primaryWorkspaceId: wsId
            )
            #expect(source == nil)
        }
    }

    // MARK: - InMemoryMemoryStore

    @Suite("InMemoryMemoryStore")
    struct MemoryStoreTests {
        private func makeMemory(
            title: String = "Title",
            content: String = "Content",
            tags: [String] = []
        ) -> Memory {
            Memory(title: title, content: content, tags: tags)
        }

        @Test("saveMemory stores and returns the memory id")
        func saveReturnsId() async throws {
            let store = InMemoryMemoryStore()
            let memory = makeMemory()

            let id = try await store.saveMemory(memory, policy: .immediate)
            #expect(id == memory.id)
        }

        @Test("fetchMemory returns nil for an unknown id")
        func fetchUnknownReturnsNil() async throws {
            let store = InMemoryMemoryStore()
            let fetched = try await store.fetchMemory(id: UUID())
            #expect(fetched == nil)
        }

        @Test("searchMemories matches title and content substrings")
        func searchMatchesTitleAndContent() async throws {
            let store = InMemoryMemoryStore()
            _ = try await store.saveMemory(makeMemory(title: "Swift tips", content: "nope"), policy: .immediate)
            _ = try await store.saveMemory(makeMemory(title: "Other", content: "loves Swift"), policy: .immediate)
            _ = try await store.saveMemory(makeMemory(title: "Unrelated", content: "nothing"), policy: .immediate)

            let results = try await store.searchMemories(query: "Swift")
            #expect(results.count == 2)
        }

        @Test("searchMemories(matchingAnyTag:) returns memories sharing at least one tag")
        func searchByTag() async throws {
            let store = InMemoryMemoryStore()
            _ = try await store.saveMemory(makeMemory(title: "A", content: "a", tags: ["swift", "ios"]), policy: .immediate)
            _ = try await store.saveMemory(makeMemory(title: "B", content: "b", tags: ["rust"]), policy: .immediate)
            _ = try await store.saveMemory(makeMemory(title: "C", content: "c", tags: ["swift"]), policy: .immediate)

            let results = try await store.searchMemories(matchingAnyTag: ["swift"])
            #expect(results.count == 2)
        }

        @Test("searchMemories(matchingAnyTag:) returns empty for no tag overlap")
        func searchByTagNoOverlap() async throws {
            let store = InMemoryMemoryStore()
            _ = try await store.saveMemory(makeMemory(tags: ["a"]), policy: .immediate)

            let results = try await store.searchMemories(matchingAnyTag: ["z"])
            #expect(results.isEmpty)
        }

        @Test("deleteMemory removes the memory")
        func deleteRemoves() async throws {
            let store = InMemoryMemoryStore()
            let memory = makeMemory()
            _ = try await store.saveMemory(memory, policy: .immediate)

            try await store.deleteMemory(id: memory.id)
            let fetched = try await store.fetchMemory(id: memory.id)
            #expect(fetched == nil)
        }

        @Test("updateMemory overwrites an existing memory in place")
        func updateOverwrites() async throws {
            let store = InMemoryMemoryStore()
            let memory = makeMemory(title: "Original")
            _ = try await store.saveMemory(memory, policy: .immediate)

            var updated = memory
            updated.title = "Updated"
            try await store.updateMemory(updated)

            let fetched = try await store.fetchMemory(id: memory.id)
            #expect(fetched?.title == "Updated")
        }

        @Test("updateMemory is a no-op for an unknown id")
        func updateUnknownIsNoOp() async throws {
            let store = InMemoryMemoryStore()
            try await store.updateMemory(makeMemory(title: "Ghost"))
            #expect(try await store.fetchAllMemories().isEmpty)
        }

        @Test("vacuum and prune are no-ops returning zero")
        func vacuumAndPruneAreNoOps() async throws {
            let store = InMemoryMemoryStore()
            _ = try await store.saveMemory(makeMemory(), policy: .immediate)

            #expect(try await store.vacuumMemories(threshold: 0.5) == 0)
            #expect(try await store.pruneMemories(matching: "x", dryRun: false) == 0)
            #expect(try await store.pruneMemories(olderThan: 100, dryRun: false) == 0)
            #expect(try await store.fetchAllMemories().count == 1)
        }
    }

    // MARK: - InMemoryMessageStore

    @Suite("InMemoryMessageStore")
    struct MessageStoreTests {
        @Test("saveMessage and fetchMessages round-trip per thread")
        func saveAndFetchPerThread() async throws {
            let store = InMemoryMessageStore()
            let threadA = UUID(), threadB = UUID()

            try await store.saveMessage(ThreadMessage(threadID: threadA, role: .user, content: "A1"))
            try await store.saveMessage(ThreadMessage(threadID: threadA, role: .assistant, content: "A2"))
            try await store.saveMessage(ThreadMessage(threadID: threadB, role: .user, content: "B1"))

            let aMessages = try await store.fetchMessages(for: threadA)
            let bMessages = try await store.fetchMessages(for: threadB)
            #expect(aMessages.count == 2)
            #expect(bMessages.count == 1)
        }

        @Test("deleteMessages removes only the targeted thread's messages")
        func deleteTargetsSingleThread() async throws {
            let store = InMemoryMessageStore()
            let threadA = UUID(), threadB = UUID()
            try await store.saveMessage(ThreadMessage(threadID: threadA, role: .user, content: "A"))
            try await store.saveMessage(ThreadMessage(threadID: threadB, role: .user, content: "B"))

            try await store.deleteMessages(for: threadA)

            #expect(try await store.fetchMessages(for: threadA).isEmpty)
            #expect(try await store.fetchMessages(for: threadB).count == 1)
        }

        @Test("fetchSnapshots decodes assistant messages with snapshot data")
        func fetchSnapshotsDecodesAssistantSnapshots() async throws {
            let store = InMemoryMessageStore()
            let thread = UUID()
            let snapshot = TurnSnapshot(
                threadID: thread,
                modelName: "test-model",
                modelRoundIndex: 1,
                maxModelRounds: 5,
                fullResponse: "Pong"
            )
            let data = try SerializationUtils.jsonEncoder.encode(snapshot)
            try await store.saveMessage(ThreadMessage(
                threadID: thread, role: .assistant, content: "Pong", snapshotData: data
            ))
            // A user message without snapshot data should be skipped.
            try await store.saveMessage(ThreadMessage(
                threadID: thread, role: .user, content: "Ping"
            ))

            let snapshots = try await store.fetchSnapshots(for: thread)
            #expect(snapshots.count == 1)
            #expect(snapshots.first?.fullResponse == "Pong")
        }

        @Test("fetchSnapshots skips assistant messages with missing or invalid snapshot data")
        func fetchSnapshotsSkipsInvalidData() async throws {
            let store = InMemoryMessageStore()
            let thread = UUID()
            try await store.saveMessage(ThreadMessage(
                threadID: thread, role: .assistant, content: "no snapshot"
            ))
            try await store.saveMessage(ThreadMessage(
                threadID: thread, role: .assistant, content: "bad snapshot",
                snapshotData: Data("not json".utf8)
            ))

            let snapshots = try await store.fetchSnapshots(for: thread)
            #expect(snapshots.isEmpty)
        }

        @Test("pruneMessages is a no-op returning zero")
        func pruneIsNoOp() async throws {
            let store = InMemoryMessageStore()
            let thread = UUID()
            try await store.saveMessage(ThreadMessage(threadID: thread, role: .user, content: "x"))

            #expect(try await store.pruneMessages(olderThan: 1000, dryRun: false) == 0)
            #expect(try await store.fetchMessages(for: thread).count == 1)
        }
    }

    // MARK: - InMemoryAgentTemplateStore

    @Suite("InMemoryAgentTemplateStore")
    struct AgentTemplateStoreTests {
        private func makeTemplate(id: UUID = UUID(), name: String = "Agent") -> AgentTemplate {
            AgentTemplate(id: id, name: name, description: "desc", systemPrompt: "You are helpful.")
        }

        @Test("saveAgentTemplate inserts a new template")
        func saveInserts() async throws {
            let store = InMemoryAgentTemplateStore()
            let template = makeTemplate()
            try await store.saveAgentTemplate(template)

            let fetched = try await store.fetchAgentTemplate(id: template.id)
            #expect(fetched == template)
        }

        @Test("saveAgentTemplate updates on id collision")
        func saveUpdatesOnCollision() async throws {
            let store = InMemoryAgentTemplateStore()
            let id = UUID()
            try await store.saveAgentTemplate(makeTemplate(id: id, name: "Original"))
            try await store.saveAgentTemplate(makeTemplate(id: id, name: "Updated"))

            let fetched = try await store.fetchAgentTemplate(id: id)
            #expect(fetched?.name == "Updated")
            #expect(try await store.fetchAllAgentTemplates().count == 1)
        }

        @Test("fetchAgentTemplate(key:) returns the first template for 'default'")
        func fetchByKeyDefaultReturnsFirst() async throws {
            let store = InMemoryAgentTemplateStore()
            let first = makeTemplate(name: "First")
            try await store.saveAgentTemplate(first)
            try await store.saveAgentTemplate(makeTemplate(name: "Second"))

            let fetched = try await store.fetchAgentTemplate(key: "default")
            #expect(fetched?.name == "First")
        }

        @Test("fetchAgentTemplate(key:) resolves a UUID string key")
        func fetchByKeyUUID() async throws {
            let store = InMemoryAgentTemplateStore()
            let template = makeTemplate()
            try await store.saveAgentTemplate(template)

            let fetched = try await store.fetchAgentTemplate(key: template.id.uuidString)
            #expect(fetched == template)
        }

        @Test("fetchAgentTemplate(key:) returns nil for a non-UUID, non-default key")
        func fetchByKeyUnknownReturnsNil() async throws {
            let store = InMemoryAgentTemplateStore()
            try await store.saveAgentTemplate(makeTemplate())

            let fetched = try await store.fetchAgentTemplate(key: "not-a-uuid")
            #expect(fetched == nil)
        }

        @Test("hasAgentTemplate returns true for a saved UUID id")
        func hasAgentTemplateTrue() async throws {
            let store = InMemoryAgentTemplateStore()
            let template = makeTemplate()
            try await store.saveAgentTemplate(template)

            #expect(await store.hasAgentTemplate(id: template.id.uuidString) == true)
        }

        @Test("hasAgentTemplate returns false for an unknown or non-UUID id")
        func hasAgentTemplateFalse() async throws {
            let store = InMemoryAgentTemplateStore()

            #expect(await store.hasAgentTemplate(id: UUID().uuidString) == false)
            #expect(await store.hasAgentTemplate(id: "not-a-uuid") == false)
        }
    }

    // MARK: - InMemoryConfigurationService

    @Suite("InMemoryConfigurationService")
    struct ConfigurationServiceTests {
        @Test("load returns the default configuration when uninitialized")
        func loadReturnsDefault() async throws {
            let service = InMemoryConfigurationService()
            let config = await service.load()
            #expect(config.activeProvider == .openAI)
        }

        @Test("load returns a custom initial configuration")
        func loadReturnsCustomInitial() async throws {
            let config = LLMConfiguration.fixture(
                endpoint: "http://localhost:11434",
                modelName: "llama3",
                apiKey: "",
                activeProvider: .ollama
            )
            let service = InMemoryConfigurationService(config: config)
            let loaded = await service.load()
            #expect(loaded.activeProvider == .ollama)
        }

        @Test("save persists and load returns the saved configuration")
        func savePersists() async throws {
            let service = InMemoryConfigurationService()
            let config = LLMConfiguration.fixture(
                endpoint: "http://localhost:11434",
                modelName: "llama3",
                apiKey: "",
                activeProvider: .ollama
            )
            try await service.save(config)
            #expect(await service.load().activeProvider == .ollama)
        }

        @Test("clear resets to the default OpenAI configuration")
        func clearResetsToDefault() async throws {
            let service = InMemoryConfigurationService()
            try await service.save(LLMConfiguration.fixture(
                endpoint: "http://localhost:11434",
                modelName: "llama3",
                apiKey: "",
                activeProvider: .ollama
            ))
            await service.clear()
            #expect(await service.load().activeProvider == .openAI)
        }

        @Test("export and import round-trip the configuration")
        func exportImportRoundTrip() async throws {
            let service = InMemoryConfigurationService()
            let config = LLMConfiguration.fixture(
                endpoint: "https://api.openai.com",
                modelName: "gpt-4",
                apiKey: "sk-test",
                activeProvider: .openAI
            )
            try await service.save(config)

            let exported = try await service.exportConfiguration()
            let fresh = InMemoryConfigurationService()
            try await fresh.importConfiguration(from: exported)
            #expect(await fresh.load().activeProvider == .openAI)
            #expect(await fresh.load().activeProviderConfiguration.modelName == "gpt-4")
        }

        @Test("restoreFromBackup returns nil (no backup support)")
        func restoreFromBackupReturnsNil() async throws {
            let service = InMemoryConfigurationService()
            let restored = try await service.restoreFromBackup()
            #expect(restored == nil)
        }

        @Test("migrateIfNeeded completes without throwing")
        func migrateIfNeededIsNoOp() async throws {
            let service = InMemoryConfigurationService()
            await service.migrateIfNeeded()
            // Still returns the default config.
            #expect(await service.load().activeProvider == .openAI)
        }
    }
}
