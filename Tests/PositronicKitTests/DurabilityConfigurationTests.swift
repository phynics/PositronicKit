import Foundation
import PKShared
import PKUtilities
import PKTestSupport
import PositronicKit
import Testing

/// PKRR-017: Persistence configuration durability validation.
///
/// Every omitted persistence store silently defaults to an in-memory implementation.
/// `validateDurability()` classifies each store as `.durable` or `.ephemeral` so mixed
/// configurations (some durable, some in-memory) are detectable at construction time.
/// `PositronicKit.init(configuration:)` logs a `.warning` on mixed durability naming the
/// specific ephemeral stores.
@Suite("PKRR-017: Persistence durability validation")
struct DurabilityConfigurationTests {
    // MARK: - isDurable defaults on InMemory stores

    @Test("InMemory stores report isDurable == false through existential dispatch")
    func inMemoryStoresAreEphemeral() {
        let config = PositronicKit.PersistenceConfiguration(
            messageStore: InMemoryMessageStore(),
            threadPersistence: InMemoryThreadPersistence(),
            workspacePersistence: InMemoryWorkspacePersistence(),
            memoryStore: InMemoryMemoryStore(),
            toolPersistence: InMemoryToolPersistence(),
            agentInstanceStore: InMemoryAgentInstanceStore(),
            requestOriginStore: InMemoryRequestOriginStore()
        )
        let report = config.validateDurability()
        #expect(report.messageStore == .ephemeral)
        #expect(report.threadPersistence == .ephemeral)
        #expect(report.workspacePersistence == .ephemeral)
        #expect(report.memoryStore == .ephemeral)
        #expect(report.toolPersistence == .ephemeral)
        #expect(report.agentInstanceStore == .ephemeral)
        #expect(report.requestOriginStore == .ephemeral)
    }

    @Test("MockPersistenceService defaults to isDurable == false")
    func mockDefaultsToEphemeral() {
        let store = MockPersistenceService()
        #expect(store.mockIsDurable == false)
        #expect(store.isDurable == false)

        let config = PositronicKit.PersistenceConfiguration(
            messageStore: store,
            threadPersistence: store,
            workspacePersistence: store,
            memoryStore: store,
            toolPersistence: store,
            agentInstanceStore: store,
            requestOriginStore: store
        )
        let report = config.validateDurability()
        #expect(report.messageStore == .ephemeral)
    }

    @Test("MockPersistenceService with mockIsDurable == true reports durable")
    func mockWithDurableFlagReportsDurable() {
        let store = MockPersistenceService()
        store.mockIsDurable = true
        #expect(store.isDurable == true)

        let config = PositronicKit.PersistenceConfiguration(
            messageStore: store,
            threadPersistence: store,
            workspacePersistence: store,
            memoryStore: store,
            toolPersistence: store,
            agentInstanceStore: store,
            requestOriginStore: store
        )
        let report = config.validateDurability()
        #expect(report.messageStore == .durable)
        #expect(report.threadPersistence == .durable)
        #expect(report.workspacePersistence == .durable)
        #expect(report.memoryStore == .durable)
        #expect(report.toolPersistence == .durable)
        #expect(report.agentInstanceStore == .durable)
        #expect(report.requestOriginStore == .durable)
    }

    // MARK: - validateDurability: all-ephemeral

    @Test("All-ephemeral config is not mixed and produces no warning")
    func allEphemeralIsNotMixed() {
        let config = PositronicKit.PersistenceConfiguration.inMemory()
        let report = config.validateDurability()
        #expect(!report.isMixed)
        #expect(report.ephemeralStoreNames.count == 7)
        #expect(report.mixedDurabilityWarning == nil)
    }

    // MARK: - validateDurability: all-durable

    @Test("All-durable config is not mixed and produces no warning")
    func allDurableIsNotMixed() {
        let durable = MockPersistenceService()
        durable.mockIsDurable = true
        let config = PositronicKit.PersistenceConfiguration(
            messageStore: durable,
            threadPersistence: durable,
            workspacePersistence: durable,
            memoryStore: durable,
            toolPersistence: durable,
            agentInstanceStore: durable,
            requestOriginStore: durable
        )
        let report = config.validateDurability()
        #expect(!report.isMixed)
        #expect(report.ephemeralStoreNames.isEmpty)
        #expect(report.mixedDurabilityWarning == nil)
    }

    // MARK: - validateDurability: mixed

    @Test("Mixed config (3 durable, 4 ephemeral) is mixed and names the ephemeral stores")
    func mixedConfigIsMixed() {
        let durable = MockPersistenceService()
        durable.mockIsDurable = true
        let config = PositronicKit.PersistenceConfiguration(
            messageStore: durable,
            threadPersistence: durable,
            workspacePersistence: durable,
            memoryStore: InMemoryMemoryStore(),
            toolPersistence: InMemoryToolPersistence(),
            agentInstanceStore: InMemoryAgentInstanceStore(),
            requestOriginStore: InMemoryRequestOriginStore()
        )
        let report = config.validateDurability()
        #expect(report.isMixed)
        #expect(report.messageStore == .durable)
        #expect(report.threadPersistence == .durable)
        #expect(report.workspacePersistence == .durable)
        #expect(report.memoryStore == .ephemeral)
        #expect(report.toolPersistence == .ephemeral)
        #expect(report.agentInstanceStore == .ephemeral)
        #expect(report.requestOriginStore == .ephemeral)
    }

    @Test("Mixed config ephemeralStoreNames lists only the ephemeral stores in declaration order")
    func mixedConfigEphemeralNames() {
        let durable = MockPersistenceService()
        durable.mockIsDurable = true
        let config = PositronicKit.PersistenceConfiguration(
            messageStore: InMemoryMessageStore(),
            threadPersistence: durable,
            workspacePersistence: InMemoryWorkspacePersistence(),
            memoryStore: durable,
            toolPersistence: InMemoryToolPersistence(),
            agentInstanceStore: durable,
            requestOriginStore: InMemoryRequestOriginStore()
        )
        let report = config.validateDurability()
        #expect(report.ephemeralStoreNames == [
            "messageStore",
            "workspacePersistence",
            "toolPersistence",
            "requestOriginStore",
        ])
    }

    @Test("Mixed config warning message names the specific ephemeral stores")
    func mixedConfigWarningMessage() throws {
        let durable = MockPersistenceService()
        durable.mockIsDurable = true
        let config = PositronicKit.PersistenceConfiguration(
            messageStore: durable,
            threadPersistence: durable,
            workspacePersistence: durable,
            memoryStore: InMemoryMemoryStore(),
            toolPersistence: InMemoryToolPersistence(),
            agentInstanceStore: InMemoryAgentInstanceStore(),
            requestOriginStore: InMemoryRequestOriginStore()
        )
        let warning = try #require(config.validateDurability().mixedDurabilityWarning)
        #expect(warning.contains("Mixed durability"))
        #expect(warning.contains("memoryStore"))
        #expect(warning.contains("toolPersistence"))
        #expect(warning.contains("agentInstanceStore"))
        #expect(warning.contains("requestOriginStore"))
        #expect(warning.contains("will not survive restart"))
        #expect(warning.contains("may reference entities that will be missing after restart"))
        // Durable stores should NOT appear in the ephemeral list
        #expect(!warning.contains("messageStore"))
        #expect(!warning.contains("threadPersistence"))
        #expect(!warning.contains("workspacePersistence"))
    }

    @Test("Single durable store among six ephemeral is mixed")
    func singleDurableIsMixed() {
        let durable = MockPersistenceService()
        durable.mockIsDurable = true
        let config = PositronicKit.PersistenceConfiguration(
            messageStore: durable
        )
        let report = config.validateDurability()
        #expect(report.isMixed)
        #expect(report.messageStore == .durable)
        #expect(report.threadPersistence == .ephemeral)
        #expect(report.ephemeralStoreNames == [
            "threadPersistence",
            "workspacePersistence",
            "memoryStore",
            "toolPersistence",
            "agentInstanceStore",
            "requestOriginStore",
        ])
    }

    @Test("Single ephemeral store among six durable is mixed")
    func singleEphemeralIsMixed() {
        let durable = MockPersistenceService()
        durable.mockIsDurable = true
        let config = PositronicKit.PersistenceConfiguration(
            messageStore: durable,
            threadPersistence: durable,
            workspacePersistence: durable,
            memoryStore: InMemoryMemoryStore(),
            toolPersistence: durable,
            agentInstanceStore: durable,
            requestOriginStore: durable
        )
        let report = config.validateDurability()
        #expect(report.isMixed)
        #expect(report.memoryStore == .ephemeral)
        #expect(report.ephemeralStoreNames == ["memoryStore"])
    }

    // MARK: - .fullyPersistent(stores:)

    @Test(".fullyPersistent accepts all 7 stores explicitly")
    func fullyPersistentAcceptsAllSeven() {
        let store = MockPersistenceService()
        let config = PositronicKit.PersistenceConfiguration.fullyPersistent(
            messageStore: store,
            threadPersistence: store,
            workspacePersistence: store,
            memoryStore: store,
            toolPersistence: store,
            agentInstanceStore: store,
            requestOriginStore: store
        )
        let report = config.validateDurability()
        #expect(!report.isMixed)
    }

    @Test(".fullyPersistent with durable stores produces no warning")
    func fullyPersistentWithDurableStoresNoWarning() {
        let durable = MockPersistenceService()
        durable.mockIsDurable = true
        let config = PositronicKit.PersistenceConfiguration.fullyPersistent(
            messageStore: durable,
            threadPersistence: durable,
            workspacePersistence: durable,
            memoryStore: durable,
            toolPersistence: durable,
            agentInstanceStore: durable,
            requestOriginStore: durable
        )
        let report = config.validateDurability()
        #expect(!report.isMixed)
        #expect(report.mixedDurabilityWarning == nil)
    }

    // MARK: - Optional-store init backward compatibility

    @Test("Optional-store init with no arguments defaults to all in-memory")
    func optionalInitDefaultsToInMemory() {
        let config = PositronicKit.PersistenceConfiguration()
        let report = config.validateDurability()
        #expect(!report.isMixed)
        #expect(report.messageStore == .ephemeral)
        #expect(report.threadPersistence == .ephemeral)
        #expect(report.workspacePersistence == .ephemeral)
        #expect(report.memoryStore == .ephemeral)
        #expect(report.toolPersistence == .ephemeral)
        #expect(report.agentInstanceStore == .ephemeral)
        #expect(report.requestOriginStore == .ephemeral)
    }

    @Test("Optional-store init with one durable store is mixed")
    func optionalInitPartialIsMixed() {
        let durable = MockPersistenceService()
        durable.mockIsDurable = true
        let config = PositronicKit.PersistenceConfiguration(
            messageStore: durable
        )
        let report = config.validateDurability()
        #expect(report.isMixed)
        #expect(report.messageStore == .durable)
        #expect(report.threadPersistence == .ephemeral)
    }

    @Test(".inMemory() factory still works and is all-ephemeral")
    func inMemoryFactoryWorks() {
        let config = PositronicKit.PersistenceConfiguration.inMemory()
        let report = config.validateDurability()
        #expect(!report.isMixed)
        #expect(report.ephemeralStoreNames.count == 7)
    }

    // MARK: - DurabilityReport properties

    @Test("DurabilityReport is Equatable")
    func durabilityReportEquatable() {
        let report1 = PositronicKit.DurabilityReport(
            messageStore: .durable,
            threadPersistence: .ephemeral,
            workspacePersistence: .durable,
            memoryStore: .ephemeral,
            toolPersistence: .durable,
            agentInstanceStore: .ephemeral,
            requestOriginStore: .durable
        )
        let report2 = PositronicKit.DurabilityReport(
            messageStore: .durable,
            threadPersistence: .ephemeral,
            workspacePersistence: .durable,
            memoryStore: .ephemeral,
            toolPersistence: .durable,
            agentInstanceStore: .ephemeral,
            requestOriginStore: .durable
        )
        #expect(report1 == report2)
        #expect(report1.isMixed)
    }

    // MARK: - PositronicKit.init(configuration:) integration

    @Test("PositronicKit init with all-ephemeral config does not crash")
    func initWithAllEphemeralDoesNotCrash() {
        _ = PositronicKit(configuration: .init(
            provider: .init(languageModel: UnconfiguredLLMService()),
            persistence: .inMemory()
        ))
    }

    @Test("PositronicKit init with all-durable config does not crash")
    func initWithAllDurableDoesNotCrash() {
        let durable = MockPersistenceService()
        durable.mockIsDurable = true
        _ = PositronicKit(configuration: .init(
            provider: .init(languageModel: UnconfiguredLLMService()),
            persistence: .fullyPersistent(
                messageStore: durable,
                threadPersistence: durable,
                workspacePersistence: durable,
                memoryStore: durable,
                toolPersistence: durable,
                agentInstanceStore: durable,
                requestOriginStore: durable
            )
        ))
    }

    @Test("PositronicKit init with mixed config does not crash (warning is logged, not thrown)")
    func initWithMixedDurabilityDoesNotCrash() {
        let durable = MockPersistenceService()
        durable.mockIsDurable = true
        let persistence = PositronicKit.PersistenceConfiguration(
            messageStore: durable,
            threadPersistence: durable,
            workspacePersistence: durable,
            memoryStore: InMemoryMemoryStore(),
            toolPersistence: InMemoryToolPersistence(),
            agentInstanceStore: InMemoryAgentInstanceStore(),
            requestOriginStore: InMemoryRequestOriginStore()
        )
        _ = PositronicKit(configuration: .init(
            provider: .init(languageModel: UnconfiguredLLMService()),
            persistence: persistence
        ))
    }
}
