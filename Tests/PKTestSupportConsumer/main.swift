import PKTestSupport
import PKContracts
import PositronicKit

let workspace = TestWorkspace()
_ = TestRuntime(workspaceRoot: workspace.root)
_ = Message.fixture(content: "consumer")
_ = MockToolCall(id: "call-1", name: "echo")
_ = GenerationStreamResultFactory.textChunk("ok")

try await ThreadRuntimeRepositoryConformanceSuite.run(staleAfter: 1) {
    InMemoryThreadRuntimeRepository(staleAfter: 1)
}
