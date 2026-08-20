import Foundation
import PKContracts
import PKUtilities

/// Protocol for persisting and querying agents.
///
/// This is a real seam — downstream consumers provide concrete adapters backed by
/// production databases:
/// - **Monad** — `AgentDataRepository` (GRDB / SQLite, `public actor`)
/// - **Yakamoz** — `SwiftDataAgentStore` (SwiftData `@ModelActor`)
///
/// The default in-process conformer is ``InMemoryAgentStore`` (array-backed actor).
/// `MockPersistenceService` in `PKTestSupport` also conforms for test wiring.
///
/// The protocol contract is exercised in `AgentStoreContractTests` against both
/// in-package conformers.
public protocol AgentStoreProtocol: DurabilityAware {
    func saveAgent(_ instance: Agent) async throws
    func fetchAgent(id: UUID) async throws -> Agent?
    func fetchAllAgents() async throws -> [Agent]
    func deleteAgent(id: UUID) async throws
    func fetchThreads(attachedToAgent agentId: UUID) async throws -> [Thread]
}
