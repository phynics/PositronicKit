import Foundation
import PKTestSupport
import PKContracts
import PositronicKit

let workspace = TestWorkspace()
_ = TestRuntime(workspaceRoot: workspace.root)
_ = TimelineRecord(title: "consumer")
_ = Message.fixture(content: "consumer")
_ = MockToolCall(id: "call-1", name: "echo")
_ = GenerationStreamResultFactory.textChunk("ok")

try await TimelineRuntimeRepositoryConformanceSuite.run {
    InMemoryTimelineRuntimeRepository()
}
