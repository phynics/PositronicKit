import Testing
@testable import PositronicKit
import PKTestSupport

@Suite("DefaultInstructions", .tags(.unit))
struct DefaultInstructionsTests {
    @Test("uses neutral workspace wording")
    func usesNeutralWorkspaceWording() {
        let output = DefaultInstructions.system()

        #expect(output.contains("Additional Workspaces"))
        #expect(!output.contains("Attached Workspaces"))
        #expect(!output.contains("user-attached"))
    }
}
