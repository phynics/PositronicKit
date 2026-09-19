import Foundation
import PKContracts
import PKTestSupport
import PositronicKit
import Testing

@Suite("Persistence durability validation", .tags(.unit))
struct DurabilityConfigurationTests {
    @Test("in-memory configuration reports six ephemeral stores")
    func inMemoryStoresAreEphemeral() {
        let report = PKRuntime.PersistenceConfiguration.inMemory().validateDurability()
        #expect(!report.isMixed)
        #expect(report.ephemeralStoreNames.count == 6)
        #expect(report.stores.map(\.name) == [
            "runtimeRepository", "workspacePersistence", "workspaceBindingRepository",
            "toolPersistence", "agentStore", "requestOriginStore",
        ])
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
        let runtimeRepository = InMemoryTimelineRuntimeRepository(isDurable: true)
        let config = PKRuntime.PersistenceConfiguration(
            runtimeRepository: runtimeRepository,
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
        let stores: [PKRuntime.DurabilityReport.Store] = [
            .init(name: "runtimeRepository", durability: .durable),
            .init(name: "workspacePersistence", durability: .durable),
            .init(name: "workspaceBindingRepository", durability: .durable),
            .init(name: "toolPersistence", durability: .durable),
            .init(name: "agentStore", durability: .ephemeral),
            .init(name: "requestOriginStore", durability: .durable),
        ]
        let first = PKRuntime.DurabilityReport(stores: stores)
        #expect(first == PKRuntime.DurabilityReport(stores: stores))
        #expect(first.durability(of: "agentStore") == .ephemeral)
        #expect(first.durability(of: "missingStore") == nil)
    }
}
