import PKTestSupport
import PositronicKit

@main
struct PKTestSupportConsumer {
    static func main() {
        let workspace = TestWorkspace()
        _ = TestRuntime(workspaceRoot: workspace.root)
        _ = Message.fixture(content: "consumer")
        _ = MockToolCall(id: "call-1", name: "echo")
        _ = ChatStreamResultFactory.textChunk("ok")
    }
}
