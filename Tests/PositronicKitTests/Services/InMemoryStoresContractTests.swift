import Foundation
@testable import PKContracts
import PKUtilities
import PKTestSupport
@testable import PositronicKit
import Testing

/// Implementation-specific checks for the in-memory persistence stores.
@Suite("In-memory stores", .tags(.unit))
struct InMemoryStoresContractTests {
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
