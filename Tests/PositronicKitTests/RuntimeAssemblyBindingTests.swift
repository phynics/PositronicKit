import Foundation
import PKContracts
import PKTestSupport
@testable import PositronicKit
import Testing

@Suite("Runtime assembly binding selection")
struct RuntimeAssemblyBindingTests {
    @Test("custom runtime repositories keep binding authority explicit")
    func customRuntimeRepositoryKeepsBindingAuthorityExplicit() {
        let repository = FailingTerminalRepository()
        let implicitBindingConfiguration = PositronicKit.PersistenceConfiguration(
            runtimeRepository: repository
        )

        #expect(
            implicitBindingConfiguration.workspaceBindingRepository
                is InMemoryWorkspaceBindingRepository
        )

        let bindingRepository = InMemoryWorkspaceBindingRepository()
        let explicitBindingConfiguration = PositronicKit.PersistenceConfiguration(
            runtimeRepository: repository,
            workspaceBindingRepository: bindingRepository
        )

        #expect(
            explicitBindingConfiguration.workspaceBindingRepository as AnyObject
                === bindingRepository as AnyObject
        )
    }
}
