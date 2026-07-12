import Foundation
@testable import PKShared
import PKUtilities
import PKTestSupport
@testable import PositronicKit
import Testing

@Suite("Context Manager Mocking Tests")
struct ContextManagerMockingTests {
    @Test("Context Manager Initialization with Mocks")
    func contextManagerInitializationWithMocks() {
        let contextManager = ContextManager(workspace: nil)

        // Just verifying initialization completes successfully
        _ = contextManager
    }
}
