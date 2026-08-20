import Foundation
import struct JSONSchema.Schema
@testable import PKContracts
import Testing

struct ToolOriginTests {
    struct LabelTool: PKContracts.Tool, @unchecked Sendable { // swiftlint:disable:this concurrency_unchecked_sendable -- reviewed test double (see docs/Concurrency/exception-manifest.md)
        let callName = "label_tool"
        let name = "Label Tool"
        let description = "A tool for testing origin labels"
        let requiresPermission = false
        var parametersSchema: Schema { ToolParameterSchema.object {}.schemaDefinition }

        func canExecute() async -> Bool { true }
        func execute(parameters _: [String: AnyCodable]) async throws -> ToolResult { .success("ok") }
    }

    @Test("workspace origin renders byte-identical prompt label")
    func workspaceOriginPromptLabelParity() {
        let tool = LabelTool()
        let origin = ToolOrigin.workspace(id: UUID(), name: "TestWorkspace")
        let rendered = tool.promptString(origin: origin)

        #expect(rendered == "- `label_tool` [Workspace: TestWorkspace]: A tool for testing origin labels")
    }

    @Test("terminal origin renders expected prompt label")
    func terminalOriginPromptLabel() {
        let tool = LabelTool()
        let origin = ToolOrigin.terminal(id: UUID(), name: "TestTerminal")
        let rendered = tool.promptString(origin: origin)

        #expect(rendered == "- `label_tool` [Terminal: TestTerminal]: A tool for testing origin labels")
    }

    @Test("global origin omits label")
    func globalOriginOmitsLabel() {
        let tool = LabelTool()
        let rendered = tool.promptString(origin: .global)

        #expect(rendered == "- `label_tool`: A tool for testing origin labels")
    }

    @Test("named origin renders custom label")
    func namedOriginRendersCustomLabel() {
        let tool = LabelTool()
        let rendered = tool.promptString(origin: .named("Custom"))

        #expect(rendered == "- `label_tool` [Custom]: A tool for testing origin labels")
    }

    @Test("ToolSource resolvedTools stamps global tools with provider origin")
    func toolProvidingResolvedToolsStampsOrigin() async {
        struct TestProvider: ToolSource {
            let toolOrigin: ToolOrigin = .workspace(id: UUID(), name: "Provider")
            func tools() async -> [AnyTool] {
                [AnyTool(LabelTool())]
            }
        }

        let provider = TestProvider()
        let resolved = await provider.resolvedTools()

        #expect(resolved.count == 1)
        #expect(resolved.first?.origin == provider.toolOrigin)
    }

    @Test("ToolSource resolvedTools preserves non-global origin")
    func toolProvidingResolvedToolsPreservesNonGlobalOrigin() async {
        struct TestProvider: ToolSource {
            let toolOrigin: ToolOrigin = .global
            func tools() async -> [AnyTool] {
                [AnyTool(LabelTool(), origin: .named("Preset"))]
            }
        }

        let resolved = await TestProvider().resolvedTools()

        #expect(resolved.first?.origin == .named("Preset"))
    }
}
