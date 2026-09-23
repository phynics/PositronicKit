import Foundation
import PKContracts
import PKTestSupport
@testable import PositronicKit
import Testing

@Suite("Persistence durability validation", .tags(.unit))
struct DurabilityConfigurationTests {
    @Test("in-memory configuration reports every store as ephemeral")
    func inMemoryStoresAreEphemeral() {
        let report = PKRuntime.PersistenceConfiguration.inMemory().validateDurability()
        #expect(!report.isMixed)
        #expect(report.ephemeralStoreNames.count == PKRuntime.DurabilityReport.Store.ID.allCases.count)
        #expect(report.stores.map(\.id) == PKRuntime.DurabilityReport.Store.ID.allCases)
        #expect(report.stores.allSatisfy { $0.durability == .ephemeral })
    }

    @Test("durable stores report no ephemeral names")
    func durableStoresAreDurable() {
        let store = MockPersistenceService()
        store.mockIsDurable = true
        let runtimeRepository = InMemoryTimelineRuntimeRepository(isDurable: true)
        let config = PKRuntime.PersistenceConfiguration.fullyPersistent(
            runtimeRepository: runtimeRepository,
            workspacePersistence: store,
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
        let runtimeRepository = InMemoryTimelineRuntimeRepository(isDurable: true)
        let config = PKRuntime.PersistenceConfiguration(
            runtimeRepository: runtimeRepository,
            workspacePersistence: durable,
            agentStore: InMemoryAgentStore(),
            requestOriginStore: InMemoryRequestOriginStore()
        )
        let report = config.validateDurability()
        #expect(report.isMixed)
        #expect(report.ephemeralStoreNames == ["agentStore", "requestOriginStore"])
        #expect(try #require(report.mixedDurabilityWarning).contains("agentStore"))
    }

    @Test("durability report remains equatable")
    func reportEquatable() {
        let stores: [PKRuntime.DurabilityReport.Store] = [
            .init(id: .runtimeRepository, durability: .durable),
            .init(id: .workspacePersistence, durability: .durable),
            .init(id: .workspaceBindingRepository, durability: .durable),
            .init(id: .agentStore, durability: .ephemeral),
            .init(id: .requestOriginStore, durability: .durable),
        ]
        let first = PKRuntime.DurabilityReport(stores: stores)
        #expect(first == PKRuntime.DurabilityReport(stores: stores))
        #expect(first.durability(of: .agentStore) == .ephemeral)
        #expect(first.durability(of: .requestOriginStore) == .durable)
    }
}
