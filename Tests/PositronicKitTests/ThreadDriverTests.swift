import Foundation
import PKTestSupport
import Testing
@testable import PositronicKit

@Suite("ThreadHandle")
struct ThreadDriverTests {
    @Test("opening a thread returns a fresh handle with stable thread identity")
    func openingReturnsThreadHandleWithStableIdentity() async throws {
        let runtime = TestRuntime(workspaceRoot: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString))
        let kit = runtime.positronicKit

        let created = try await kit.threadManager.createThread(title: "Cursor")
        let first: ThreadHandle = kit.openThread(created.id)
        let second = kit.openThread(created.id)

        #expect(first.threadID == created.id)
        #expect(second.threadID == created.id)
        #expect(first.id == second.id)
    }

    @Test("opening returns fresh handles with stable thread identity and no persistence I/O")
    func openingReturnsFreshHandlesWithStableIdentity() async throws {
        let runtime = TestRuntime(workspaceRoot: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString))
        let kit = runtime.positronicKit

        let created = try await kit.threadManager.createThread(title: "Cursor")
        let first = kit.openThread(created.id)
        let second = kit.openThread(created.id)

        #expect(first.id == created.id)
        #expect(second.id == created.id)
        #expect(first.id == second.id)
    }

    @Test("opening does not persist a thread")
    func openingDoesNotPersistAThread() async throws {
        let runtime = TestRuntime(workspaceRoot: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString))
        let kit = runtime.positronicKit
        let id = UUID()

        _ = kit.openThread(id)

        #expect(try await runtime.persistence.fetchThread(id: id) == nil)
    }

    @Test("opening performs no persistence I/O even against a store that would fail if touched")
    func openingPerformsNoPersistenceIOAgainstFailingStore() async throws {
        // `FailingThreadPersistence` throws on every fetch/save/delete call. If
        // `openThread(_:)` performed any persistence lookup or write, constructing the
        // driver below would throw. It must not: opening is pure value construction.
        let failingThreadStore = FailingThreadPersistence(
            fetchFails: true,
            saveFails: true,
            deleteFails: true
        )
        let kit = PositronicKit(configuration: .init(
            provider: .init(languageModel: UnconfiguredLLMService()),
            persistence: .init(threadPersistence: failingThreadStore)
        ))

        let id = UUID()
        let driver = kit.openThread(id)
        #expect(driver.id == id)
    }

    @Test("send delegates through the facade run path")
    func sendDelegatesThroughFacadeRunPath() async throws {
        let runtime = TestRuntime(workspaceRoot: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString))
        runtime.llm.mockClient.nextResponse = "reply"
        let kit = runtime.positronicKit
        let thread = try await kit.threadManager.createThread(title: "Driver")
        let agent = try await kit.agents.create(name: "Driver Agent", description: "test")
        try await kit.agents.attach(agent.id, to: thread.id)
        let driver = kit.openThread(thread.id)

        let events = try await driver.send("hello").collect()

        #expect(events.contains(where: {
            if case let .completion(.generationCompleted(message, _)) = $0 {
                return message.content == "reply"
            }
            return false
        }))

        runtime.llm.mockClient.nextResponse = "second reply"
        _ = try await driver.send("follow up").collect()

        #expect(try await runtime.persistence.fetchMessages(for: driver.id).map(\.content) == [
            "hello", "reply", "follow up", "second reply"
        ])
    }
}
