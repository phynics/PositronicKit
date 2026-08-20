import Foundation
import PKContracts
import PKUtilities

/// Protocol for persisting and querying agent instances.
///
/// This is a real seam — downstream consumers provide concrete adapters backed by
/// production databases:
/// - **Monad** — `AgentInstanceDataRepository` (GRDB / SQLite, `public actor`)
/// - **Yakamoz** — `SwiftDataAgentInstanceStore` (SwiftData `@ModelActor`)
///
/// The default in-process conformer is ``InMemoryAgentInstanceStore`` (array-backed actor).
/// `MockPersistenceService` in `PKTestSupport` also conforms for test wiring.
///
/// The protocol contract is exercised in `AgentInstanceStoreContractTests` against both
/// in-package conformers.
public protocol AgentInstanceStoreProtocol: DurabilityAware {
    func saveAgentInstance(_ instance: AgentInstance) async throws
    func fetchAgentInstance(id: UUID) async throws -> AgentInstance?
    func fetchAllAgentInstances() async throws -> [AgentInstance]
    func deleteAgentInstance(id: UUID) async throws
    func fetchThreads(attachedToAgent agentInstanceId: UUID) async throws -> [Thread]
}
