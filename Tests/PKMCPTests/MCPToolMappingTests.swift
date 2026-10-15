import Foundation
import MCP
import PKContracts
import Testing
@testable import PKMCP

@Suite("MCP tool mapping")
struct MCPToolMappingTests {
    @Test("annotations policy requires permission unless readOnlyHint is true")
    func annotationsPolicy() throws {
        let readOnly = Tool(
            name: "read",
            description: "read",
            inputSchema: .object(["type": "object"]),
            annotations: Tool.Annotations(readOnlyHint: true)
        )
        let mutating = Tool(
            name: "write",
            description: "write",
            inputSchema: .object(["type": "object"]),
            annotations: Tool.Annotations(readOnlyHint: false)
        )
        let unknown = Tool(
            name: "unknown",
            description: "unknown",
            inputSchema: .object(["type": "object"])
        )

        #expect(requiresPermission(for: readOnly, policy: .annotations) == false)
        #expect(requiresPermission(for: mutating, policy: .annotations) == true)
        #expect(requiresPermission(for: unknown, policy: .annotations) == true)
    }

    @Test("always and never policies override annotations")
    func overridePolicies() {
        let readOnly = Tool(
            name: "read",
            description: "read",
            inputSchema: .object(["type": "object"]),
            annotations: Tool.Annotations(readOnlyHint: true)
        )
        #expect(requiresPermission(for: readOnly, policy: .always) == true)
        #expect(requiresPermission(for: readOnly, policy: .never) == false)
    }

    @Test("the input schema becomes the workspace parameters schema")
    func schemaMapping() throws {
        let tool = Tool(
            name: "search",
            title: "Search",
            description: "Search things",
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "query": .object(["type": "string"])
                ]),
            ])
        )
        guard case let .custom(definition) = MCPToolMapping.toolReference(for: tool, permission: .never) else {
            Issue.record("expected a custom tool reference")
            return
        }
        #expect(definition.id == "search")
        #expect(definition.name == "Search")
        #expect(definition.description == "Search things")
        #expect(definition.parametersSchema["type"]?.asString == "object")
        let properties = definition.parametersSchema["properties"]?.asDictionary
        #expect(properties?["query"]?.asDictionary?["type"]?.asString == "string")
    }

    @Test("text content is joined and non-text parts become typed placeholders")
    func contentMapping() {
        let content: [MCP.Tool.Content] = [
            .text(text: "first", annotations: nil, _meta: nil),
            .image(data: "AAAA", mimeType: "image/png", annotations: nil, _meta: nil),
            .audio(data: "BBBB", mimeType: "audio/wav", annotations: nil, _meta: nil),
            .resourceLink(uri: "file:///tmp/a.txt", name: "a.txt"),
        ]
        let output = MCPToolMapping.output(from: content, structuredContent: nil)
        #expect(output.contains("first"))
        #expect(output.contains("[image content: image/png]"))
        #expect(output.contains("[audio content: audio/wav]"))
        #expect(output.contains("[resource link: a.txt <file:///tmp/a.txt>]"))
    }

    @Test("structured content is appended when present")
    func structuredContentMapping() {
        let output = MCPToolMapping.output(
            from: [],
            structuredContent: .object(["answer": .int(42)])
        )
        #expect(output.contains("answer"))
        #expect(output.contains("42"))
    }

    @Test("arguments map to MCP values and back")
    func argumentRoundTrip() {
        let arguments: [String: AnyCodable] = [
            "text": "hello",
            "count": .integer(3),
            "enabled": true,
            "nested": .dictionary(["key": .array([.string("a"), .number(1.5)])]),
        ]
        let mapped = MCPToolMapping.value(from: arguments)
        #expect(mapped["text"]?.stringValue == "hello")
        #expect(mapped["count"]?.intValue == 3)
        #expect(mapped["enabled"]?.boolValue == true)
    }

    private func requiresPermission(for tool: Tool, policy: MCPPermissionPolicy) -> Bool {
        guard case let .custom(definition) = MCPToolMapping.toolReference(for: tool, permission: policy) else {
            return false
        }
        return definition.requiresPermission
    }
}
