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
/// The protocol contract is exercised in `RequestOriginStoreContractTests` against both
/// in-package conformers.

import PKShared
import PKUtilities
import Foundation

public protocol RequestOriginStoreProtocol: Sendable {
    func saveOrigin(_ origin: RequestOriginIdentity) async throws
    func fetchOrigin(id: UUID) async throws -> RequestOriginIdentity?
    func fetchAllOrigins() async throws -> [RequestOriginIdentity]
    func deleteOrigin(id: UUID) async throws -> Bool
}
