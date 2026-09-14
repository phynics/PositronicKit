import Foundation
@testable import PKContracts
import PKUtilities
import PKTestSupport
@testable import PositronicKit
import Testing

/// Implementation-specific checks for the in-memory persistence stores.
///
/// Generic tool persistence behavior is exercised through the public
/// ``ToolPersistenceConformanceSuite``. These checks retain only the in-memory source-label
/// presentation, which is intentionally outside that protocol's universal contract.
@Suite("In-memory stores", .tags(.unit))
struct InMemoryStoresContractTests {
    @Suite("InMemoryToolPersistence source labels", .tags(.unit))
    struct ToolPersistenceTests {
        private func makeWorkspace(
            id: UUID = UUID(),
            location: WorkspaceReference.WorkspaceLocation = .runtime,
            uri: WorkspaceURI = WorkspaceURI(host: "localhost", path: "/tmp/ws")
        ) -> WorkspaceReference {
            WorkspaceReference(id: id, uri: uri, location: location)
        }

        @Test("fetchToolSource returns the attached-workspace label")
        func fetchToolSourceAttachedWorkspace() async throws {
            let store = InMemoryToolPersistence()
            let wsID = UUID()
            await store.replaceWorkspaces([makeWorkspace(id: wsID, location: .attached)])
            try await store.addToolToWorkspace(workspaceID: wsID, tool: .known("t"))

            let source = try await store.fetchToolSource(
                named: "t", in: [wsID], preferring: UUID()
            )
            #expect(source == "Additional Workspace")
        }

        @Test("fetchToolSource returns the primary-workspace label")
        func fetchToolSourcePrimaryWorkspace() async throws {
            let store = InMemoryToolPersistence()
            let wsID = UUID()
            await store.replaceWorkspaces([makeWorkspace(id: wsID, location: .runtimeTimeline)])
            try await store.addToolToWorkspace(workspaceID: wsID, tool: .known("t"))

            let source = try await store.fetchToolSource(
                named: "t", in: [wsID], preferring: wsID
            )
            #expect(source == "Primary Workspace")
        }

        @Test("fetchToolSource returns a URI-based label for another runtime workspace")
        func fetchToolSourceOtherRuntimeWorkspace() async throws {
            let store = InMemoryToolPersistence()
            let wsID = UUID()
            let uri = WorkspaceURI(host: "localhost", path: "/projects/extra")
            await store.replaceWorkspaces([
                makeWorkspace(id: wsID, location: .runtimeTimeline, uri: uri)
            ])
            try await store.addToolToWorkspace(workspaceID: wsID, tool: .known("t"))

            let source = try await store.fetchToolSource(
                named: "t", in: [wsID], preferring: UUID()
            )
            #expect(source?.hasPrefix("Workspace:") == true)
            #expect(source?.contains("/projects/extra") == true)
        }
    }

    // MARK: - InMemoryMessageStore

    @Suite("InMemoryMessageStore", .tags(.unit))
    struct MessageStoreTests {
        @Test("saveMessage and fetchMessages round-trip per timeline")
        func saveAndFetchPerTimeline() async throws {
            let store = InMemoryMessageStore()
            let timelineA = UUID(), timelineB = UUID()

            try await store.saveMessage(TimelineMessage(timelineID: timelineA, role: .user, content: "A1"))
            try await store.saveMessage(TimelineMessage(timelineID: timelineA, role: .assistant, content: "A2"))
            try await store.saveMessage(TimelineMessage(timelineID: timelineB, role: .user, content: "B1"))

            let aMessages = try await store.fetchMessages(for: timelineA)
            let bMessages = try await store.fetchMessages(for: timelineB)
            #expect(aMessages.count == 2)
            #expect(bMessages.count == 1)
        }

        @Test("deleteMessages removes only the targeted timeline's messages")
        func deleteTargetsSingleTimeline() async throws {
            let store = InMemoryMessageStore()
            let timelineA = UUID(), timelineB = UUID()
            try await store.saveMessage(TimelineMessage(timelineID: timelineA, role: .user, content: "A"))
            try await store.saveMessage(TimelineMessage(timelineID: timelineB, role: .user, content: "B"))

            try await store.deleteMessages(for: timelineA)

            #expect(try await store.fetchMessages(for: timelineA).isEmpty)
            #expect(try await store.fetchMessages(for: timelineB).count == 1)
        }

        @Test("fetchSnapshots decodes assistant messages with snapshot data")
        func fetchSnapshotsDecodesAssistantSnapshots() async throws {
            let store = InMemoryMessageStore()
            let timeline = UUID()
            let snapshot = TurnSnapshot(
                timelineID: timeline,
                modelName: "test-model",
                modelRoundIndex: 1,
                maxModelRounds: 5,
                fullResponse: "Pong"
            )
            let data = try SerializationUtils.jsonEncoder.encode(snapshot)
            try await store.saveMessage(TimelineMessage(
                timelineID: timeline, role: .assistant, content: "Pong", snapshotData: data
            ))
            // A user message without snapshot data should be skipped.
            try await store.saveMessage(TimelineMessage(
                timelineID: timeline, role: .user, content: "Ping"
            ))

            let snapshots = try await store.fetchSnapshots(for: timeline)
            #expect(snapshots.count == 1)
            #expect(snapshots.first?.fullResponse == "Pong")
        }

        @Test("fetchSnapshots skips assistant messages with missing or invalid snapshot data")
        func fetchSnapshotsSkipsInvalidData() async throws {
            let store = InMemoryMessageStore()
            let timeline = UUID()
            try await store.saveMessage(TimelineMessage(
                timelineID: timeline, role: .assistant, content: "no snapshot"
            ))
            try await store.saveMessage(TimelineMessage(
                timelineID: timeline, role: .assistant, content: "bad snapshot",
                snapshotData: Data("not json".utf8)
            ))

            let snapshots = try await store.fetchSnapshots(for: timeline)
            #expect(snapshots.isEmpty)
        }

        @Test("pruneMessages is a no-op returning zero")
        func pruneIsNoOp() async throws {
            let store = InMemoryMessageStore()
            let timeline = UUID()
            try await store.saveMessage(TimelineMessage(timelineID: timeline, role: .user, content: "x"))

            #expect(try await store.pruneMessages(olderThan: 1000, dryRun: false) == 0)
            #expect(try await store.fetchMessages(for: timeline).count == 1)
        }
    }

    // MARK: - InMemoryAgentTemplateStore

    @Suite("InMemoryAgentTemplateStore", .tags(.unit))
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

    @Suite("InMemoryConfigurationService", .tags(.unit))
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
