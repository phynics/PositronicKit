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
/// The protocol contract is exercised by the reusable `AgentStoreConformanceSuite` in
/// `PKTestSupport` against in-package and downstream conformers.
///
/// Saves replace an existing Agent with the same ID. Fetch-all includes every saved ID, deleting
/// one Agent leaves unrelated Agents unchanged, and deleting an unknown ID is idempotent.
/// `fetchThreads(attachedToAgent:)` returns exactly the Threads attached to the supplied Agent;
/// storage order is not part of the contract.
public protocol AgentStoreProtocol: DurabilityAware {
    func saveAgent(_ instance: Agent) async throws
    func fetchAgent(id: UUID) async throws -> Agent?
    func fetchAllAgents() async throws -> [Agent]
    func deleteAgent(id: UUID) async throws
    func fetchThreads(attachedToAgent agentId: UUID) async throws -> [Thread]
}
