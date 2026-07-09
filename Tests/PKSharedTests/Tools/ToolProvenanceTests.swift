import Foundation
@testable import PKShared
import Testing

struct ToolProvenanceTests {
    struct LabelTool: PKShared.Tool, @unchecked Sendable {
        let id = "label_tool"
        let name = "Label Tool"
        let description = "A tool for testing provenance labels"
        let requiresPermission = false
        var parametersSchema: [String: AnyCodable] { [:] }

        func canExecute() async -> Bool { true }
        func execute(parameters: [String: Any]) async throws -> ToolResult { .success("ok") }
    }

    @Test("workspace provenance renders byte-identical prompt label")
    func workspaceProvenancePromptLabelParity() {
        let tool = LabelTool()
        let provenance = ToolProvenance.workspace(id: UUID(), name: "TestWorkspace")
        let rendered = tool.promptString(provenance: provenance)

        #expect(rendered == "- `label_tool` [Workspace: TestWorkspace]: A tool for testing provenance labels")
    }

    @Test("terminal provenance renders expected prompt label")
    func terminalProvenancePromptLabel() {
        let tool = LabelTool()
        let provenance = ToolProvenance.terminal(id: UUID(), name: "TestTerminal")
        let rendered = tool.promptString(provenance: provenance)

        #expect(rendered == "- `label_tool` [Terminal: TestTerminal]: A tool for testing provenance labels")
    }

    @Test("global provenance omits label")
    func globalProvenanceOmitsLabel() {
        let tool = LabelTool()
        let rendered = tool.promptString(provenance: .global)

        #expect(rendered == "- `label_tool`: A tool for testing provenance labels")
    }

    @Test("named provenance renders custom label")
    func namedProvenanceRendersCustomLabel() {
        let tool = LabelTool()
        let rendered = tool.promptString(provenance: .named("Custom"))

        #expect(rendered == "- `label_tool` [Custom]: A tool for testing provenance labels")
    }

    @Test("ToolProviding resolvedTools stamps global tools with provider provenance")
    func toolProvidingResolvedToolsStampsProvenance() async {
        struct TestProvider: ToolProviding {
            let toolProvenance: ToolProvenance = .workspace(id: UUID(), name: "Provider")
            func provideTools() async -> [AnyTool] {
                [AnyTool(LabelTool())]
            }
        }

        let provider = TestProvider()
        let resolved = await provider.resolvedTools()

        #expect(resolved.count == 1)
        #expect(resolved.first?.provenance == provider.toolProvenance)
    }

    @Test("ToolProviding resolvedTools preserves non-global provenance")
    func toolProvidingResolvedToolsPreservesNonGlobalProvenance() async {
        struct TestProvider: ToolProviding {
            let toolProvenance: ToolProvenance = .global
            func provideTools() async -> [AnyTool] {
                [AnyTool(LabelTool(), provenance: .named("Preset"))]
            }
        }

        let resolved = await TestProvider().resolvedTools()

        #expect(resolved.first?.provenance == .named("Preset"))
    }
}
