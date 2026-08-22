import Foundation
import PKContracts
import PKTestSupport
import PositronicKit
import Testing

@Suite("Persistence durability validation")
struct DurabilityConfigurationTests {
    @Test("in-memory configuration reports six ephemeral stores")
    func inMemoryStoresAreEphemeral() {
        let report = PositronicKit.PersistenceConfiguration.inMemory().validateDurability()
        #expect(!report.isMixed)
        #expect(report.ephemeralStoreNames.count == 6)
        #expect(report.messageStore == .ephemeral)
        #expect(report.threadPersistence == .ephemeral)
        #expect(report.workspacePersistence == .ephemeral)
        #expect(report.toolPersistence == .ephemeral)
        #expect(report.agentStore == .ephemeral)
        #expect(report.requestOriginStore == .ephemeral)
    }

    @Test("durable stores report no ephemeral names")
    func durableStoresAreDurable() {
        let store = MockPersistenceService()
        store.mockIsDurable = true
        let config = PositronicKit.PersistenceConfiguration.fullyPersistent(
            messageStore: store,
            threadPersistence: store,
            workspacePersistence: store,
            toolPersistence: store,
            agentStore: store,
            requestOriginStore: store
        )
        let report = config.validateDurability()
        #expect(!report.isMixed)
        #expect(report.ephemeralStoreNames.isEmpty)
        #expect(report.mixedDurabilityWarning == nil)
    }

    @Test("mixed durability names the ephemeral stores")
    func mixedStoresAreNamed() throws {
        let durable = MockPersistenceService()
        durable.mockIsDurable = true
        let config = PositronicKit.PersistenceConfiguration(
            messageStore: durable,
            threadPersistence: durable,
            workspacePersistence: durable,
            toolPersistence: InMemoryToolPersistence(),
            agentStore: InMemoryAgentStore(),
            requestOriginStore: InMemoryRequestOriginStore()
        )
        let report = config.validateDurability()
        #expect(report.isMixed)
        #expect(report.ephemeralStoreNames == ["toolPersistence", "agentStore", "requestOriginStore"])
        #expect(try #require(report.mixedDurabilityWarning).contains("toolPersistence"))
    }

    @Test("durability report remains equatable")
    func reportEquatable() {
        let first = PositronicKit.DurabilityReport(
            messageStore: .durable,
            threadPersistence: .ephemeral,
            workspacePersistence: .durable,
            toolPersistence: .durable,
            agentStore: .ephemeral,
            requestOriginStore: .durable
        )
        #expect(first == PositronicKit.DurabilityReport(
            messageStore: .durable,
            threadPersistence: .ephemeral,
            workspacePersistence: .durable,
            toolPersistence: .durable,
            agentStore: .ephemeral,
            requestOriginStore: .durable
        ))
    }
}
