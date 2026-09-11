/// Protocol for persisting external request-origin identities and their hosted tool metadata.
///
/// This is a real seam — downstream consumers provide concrete adapters backed by
/// production databases:
/// - **Monad** — `RequestOriginRepository` (GRDB / SQLite, `public actor`)
/// - **Yakamoz** — `SwiftDataRequestOriginStore` (SwiftData `@ModelActor`)
///
/// The default in-process conformer is ``InMemoryRequestOriginStore`` (array-backed actor).
/// `MockPersistenceService` in `PKTestSupport` also conforms for test wiring.
///
/// The protocol contract is exercised by the reusable `RequestOriginStoreConformanceSuite` in
/// `PKTestSupport` against in-package and downstream conformers.
///
/// Saves replace an existing origin with the same ID. Fetch-all includes every saved ID, deleting
/// an existing origin returns `true`, deleting an unknown ID returns `false`, and deletion does
/// not affect unrelated origins.

import PKContracts
import PKUtilities
import Foundation

public protocol RequestOriginStoreProtocol: DurabilityAware {
    func saveOrigin(_ origin: RequestOriginIdentity) async throws
    func fetchOrigin(id: UUID) async throws -> RequestOriginIdentity?
    func fetchAllOrigins() async throws -> [RequestOriginIdentity]
    func deleteOrigin(id: UUID) async throws -> Bool
}
