import ErrorKit
import Foundation
import PKContracts

extension TurnDiagnostic {
    /// A diagnostic for a dependency that failed with `error`, carrying the error's identity and
    /// its user-facing message.
    init(dependency: TurnDependency, operation: String, entityID: String, error: Error) {
        self.init(
            dependency: dependency,
            operation: operation,
            entityID: entityID,
            errorIdentity: TurnEvent.ErrorIdentity.extracting(from: error),
            message: ErrorKit.userFriendlyMessage(for: error)
        )
    }
}
