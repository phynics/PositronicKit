import Foundation
import PKTestSupport
import Testing

@Suite("TestRuntime")
struct TestRuntimeTests {
    @Test("Agent capability shares facade state")
    func agentCapabilitySharesFacadeState() async throws {
        let runtime = TestRuntime(
            workspaceRoot: FileManager.default.temporaryDirectory
                .appendingPathComponent("test-runtime-\(UUID().uuidString)")
        )

        let agent = try await runtime.agents.create(name: "Shared Agent", description: "fixture")
        #expect(try await runtime.positronicKit.agents.get(agent.id)?.id == agent.id)
    }
}
