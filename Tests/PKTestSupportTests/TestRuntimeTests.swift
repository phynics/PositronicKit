import Foundation
import PKTestSupport
import Testing

@Suite("TestRuntime")
struct TestRuntimeTests {
    @Test("agent manager is the facade-owned instance")
    func agentManagerIsFacadeOwnedInstance() {
        let runtime = TestRuntime(
            workspaceRoot: FileManager.default.temporaryDirectory
                .appendingPathComponent("test-runtime-agent-manager")
        )

        #expect(runtime.agentManager === runtime.positronicKit.agentManager)
    }
}
