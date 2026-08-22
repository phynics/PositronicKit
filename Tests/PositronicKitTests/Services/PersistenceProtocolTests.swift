import Foundation
@testable import PositronicKit
import struct PositronicKit.Thread
@testable import PKContracts
import PKUtilities
import Testing

struct PersistenceProtocolTests {
    /// This test verifies that we can define a mock that conforms to all new domain protocols
    /// effectively replacing the God protocol with composed requirements.
    @Test("Protocol Composition Test")
    func protocolComposition() {
        let mock = MockPersistenceStore()

        // Verify it conforms to all required domains
        let _: ThreadMessageStoreProtocol = mock
        let _: ThreadPersistenceProtocol = mock
        let _: AgentTemplateStoreProtocol = mock
        let _: WorkspaceStore = mock
        let _: ToolPersistenceProtocol = mock
    }
}

/// Minimal mock to verify protocol definitions exist
final class MockPersistenceStore:
    ThreadMessageStoreProtocol,
    ThreadPersistenceProtocol,
    AgentTemplateStoreProtocol,
    WorkspaceStore,
    ToolPersistenceProtocol,
    @unchecked Sendable // swiftlint:disable:this concurrency_unchecked_sendable -- reviewed test double (see docs/Concurrency/exception-manifest.md)
{
    // MessageStoreProtocol
    func saveMessage(_: ThreadMessage) async throws {}
    func fetchMessages(for _: UUID) async throws -> [ThreadMessage] {
        []
    }

    func deleteMessages(for _: UUID) async throws {}
    func pruneMessages(olderThan _: TimeInterval, dryRun _: Bool) async throws -> Int {
        0
    }

    func fetchSnapshots(for _: UUID) async throws -> [TurnSnapshot] {
        []
    }

    // ThreadPersistenceProtocol
    func saveThread(_: Thread) async throws {}
    func fetchThread(id _: UUID) async throws -> Thread? {
        nil
    }

    func fetchAllThreads(includeArchived _: Bool) async throws -> [Thread] {
        []
    }

    func deleteThread(id _: UUID) async throws {}
    func pruneThreads(olderThan _: TimeInterval, excluding _: [UUID], dryRun _: Bool) async throws -> Int {
        0
    }

    // AgentTemplateStoreProtocol
    func saveAgentTemplate(_: AgentTemplate) async throws {}
    func fetchAgentTemplate(id _: UUID) async throws -> AgentTemplate? {
        nil
    }

    func fetchAgentTemplate(key _: String) async throws -> AgentTemplate? {
        nil
    }

    func fetchAllAgentTemplates() async throws -> [AgentTemplate] {
        []
    }

    func hasAgentTemplate(id _: String) async -> Bool {
        false
    }

    // WorkspaceStore
    func saveWorkspace(_: WorkspaceReference) async throws {}
    func fetchWorkspace(id _: UUID) async throws -> WorkspaceReference? {
        nil
    }

    func fetchWorkspace(id _: UUID, includeTools _: Bool) async throws -> WorkspaceReference? {
        nil
    }

    func fetchAllWorkspaces() async throws -> [WorkspaceReference] {
        []
    }

    func deleteWorkspace(id _: UUID) async throws {}

    // ToolPersistenceProtocol
    func addToolToWorkspace(workspaceId _: UUID, tool _: ToolReference) async throws {}
    func syncTools(workspaceId _: UUID, tools _: [ToolReference]) async throws {}
    func fetchTools(forWorkspaces _: [UUID]) async throws -> [ToolReference] {
        []
    }

    func fetchOriginTools(originId _: UUID) async throws -> [ToolReference] {
        []
    }

    func findWorkspaceId(forToolId _: String, in _: [UUID]) async throws -> UUID? {
        nil
    }

    func fetchToolSource(toolId _: String, workspaceIds _: [UUID], primaryWorkspaceId _: UUID?) async throws -> String? {
        nil
    }
}
