import Foundation
@testable import PKShared
import PKTestSupport
@testable import PositronicKit
import Testing

@Suite("Turn Briefing Builder Mocking Tests")
struct TurnBriefingBuilderMockingTests {
    @Test("Turn Briefing Builder Initialization with Mocks")
    func turnBriefingBuilderInitializationWithMocks() {
        let turnBriefingBuilder = TurnBriefingBuilder(workspace: nil)

        // Just verifying initialization completes successfully
        _ = turnBriefingBuilder
    }
}
