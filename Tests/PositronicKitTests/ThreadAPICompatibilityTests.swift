import Foundation
import PKShared
import PKTestSupport
import struct PositronicKit.Thread
import PositronicKit
import Testing

@Suite("Thread API compatibility")
struct ThreadAPICompatibilityTests {
    @Test("the canonical thread facade creates and opens a thread")
    func canonicalThreadFacade() async throws {
        let runtime = TestRuntime(workspaceRoot: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString))
        let kit = runtime.positronicKit

        let thread = try await kit.threadManager.createThread(title: "Canonical")
        let driver = kit.openThread(thread.id)

        #expect(thread.title == "Canonical")
        #expect(driver.threadID == thread.id)
    }

    @Test("the canonical persistence configuration consumes a legacy timeline store")
    @available(*, deprecated, message: "Intentional legacy API compatibility coverage.")
    func canonicalPersistenceConfigurationConsumesLegacyStore() {
        let legacyStore = LegacyTimelinePersistence()
        let configuration = PositronicKit.PersistenceConfiguration(threadPersistence: legacyStore)
        let kit = PositronicKit(configuration: .init(
            provider: .init(languageModel: UnconfiguredLLMService()),
            persistence: configuration
        ))

        _ = kit
    }

    @Test("canonical persistence configuration exposes canonical durability naming")
    @available(*, deprecated, message: "Intentional legacy API compatibility coverage.")
    func canonicalPersistenceConfigurationUsesThreadDurabilityNaming() {
        let configuration = PositronicKit.PersistenceConfiguration(
            threadPersistence: InMemoryThreadPersistence()
        )
        let report = configuration.validateDurability()

        #expect(report.threadPersistence == .ephemeral)
        #expect(legacyTimelinePersistenceValue(from: report) == report.threadPersistence)
    }

    @available(*, deprecated, message: "Intentional legacy API compatibility coverage.")
    private func legacyTimelinePersistenceValue(
        from report: PositronicKit.DurabilityReport
    ) -> PositronicKit.StoreDurability {
        report.timelinePersistence
    }

    @available(*, deprecated, message: "Intentional legacy API compatibility coverage.")
    private actor LegacyTimelinePersistence: TimelinePersistenceProtocol {
        private let backing = MockTimelinePersistence()

        func saveTimeline(_ timeline: Timeline) async throws {
            try await backing.saveTimeline(timeline)
        }

        func fetchTimeline(id: UUID) async throws -> Timeline? {
            try await backing.fetchTimeline(id: id)
        }

        func fetchAllTimelines(includeArchived: Bool) async throws -> [Timeline] {
            try await backing.fetchAllTimelines(includeArchived: includeArchived)
        }

        func deleteTimeline(id: UUID) async throws {
            try await backing.deleteTimeline(id: id)
        }

        func pruneTimelines(
            olderThan timeInterval: TimeInterval,
            excluding excludedTimelineIds: [UUID],
            dryRun: Bool
        ) async throws -> Int {
            try await backing.pruneTimelines(
                olderThan: timeInterval,
                excluding: excludedTimelineIds,
                dryRun: dryRun
            )
        }
    }
}
