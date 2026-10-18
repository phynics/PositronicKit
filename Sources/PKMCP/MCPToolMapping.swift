import Foundation
import MCP
import PKContracts

/// Pure MCP-to-PositronicKit value mapping.
enum MCPToolMapping {
    /// Maps one MCP tool to the runtime's workspace tool reference.
    static func toolReference(
        for tool: MCP.Tool,
        permission: MCPPermissionPolicy
    ) -> ToolReference {
        let requiresPermission: Bool
        switch permission {
        case .always:
            requiresPermission = true
        case .never:
            requiresPermission = false
        case .annotations:
            // Annotations are untrusted hints. Only an explicit `readOnlyHint == true` suppresses
            // the approval gate; an absent or false hint requires permission.
            requiresPermission = tool.annotations.readOnlyHint != true
        }

        let schema = anyCodable(tool.inputSchema).asDictionary ?? [:]
        let definition = ToolDefinition(
            id: tool.name,
            name: tool.title ?? tool.name,
            description: tool.description ?? "",
            parametersSchema: schema,
            requiresPermission: requiresPermission
        )
        return .custom(definition)
    }

    /// Maps runtime tool arguments to the SDK's `Value` type.
    static func value(from arguments: [String: AnyCodable]) -> [String: MCP.Value] {
        arguments.mapValues(value(from:))
    }

    /// Maps one runtime argument value to the SDK's `Value` type.
    static func value(from anyCodable: AnyCodable) -> MCP.Value {
        switch anyCodable {
        case let .string(value):
            return .string(value)
        case let .integer(value):
            return .int(Int(value))
        case let .unsignedInteger(value):
            if let exact = Int(exactly: value) {
                return .int(exact)
            }
            return .double(Double(value))
        case let .number(value):
            return .double(value)
        case let .boolean(value):
            return .bool(value)
        case let .dictionary(value):
            return .object(value.mapValues(value(from:)))
        case let .array(value):
            return .array(value.map(value(from:)))
        case .null:
            return .null
        }
    }

    /// Maps an SDK `Value` to the runtime's `AnyCodable` type.
    static func anyCodable(_ value: MCP.Value) -> AnyCodable {
        switch value {
        case .null:
            return .null
        case let .bool(value):
            return .boolean(value)
        case let .int(value):
            return .integer(Int64(value))
        case let .double(value):
            return .number(value)
        case let .string(value):
            return .string(value)
        case let .data(_, data):
            return .string(data.base64EncodedString())
        case let .array(value):
            return .array(value.map(anyCodable))
        case let .object(value):
            return .dictionary(value.mapValues(anyCodable))
        }
    }

    /// Renders an MCP tool result as the model-facing output string.
    ///
    /// Text parts are joined in order. Image, audio, and resource parts become a typed
    /// placeholder line in v1. Structured content is appended when present.
    static func output(
        from content: [MCP.Tool.Content],
        structuredContent: MCP.Value?
    ) -> String {
        var lines: [String] = []
        for part in content {
            switch part {
            case let .text(text, _, _):
                lines.append(text)
            case let .image(_, mimeType, _, _):
                lines.append("[image content: \(mimeType)]")
            case let .audio(_, mimeType, _, _):
                lines.append("[audio content: \(mimeType)]")
            case .resource:
                lines.append("[embedded resource content]")
            case let .resourceLink(uri, name, _, _, _, _):
                lines.append("[resource link: \(name) <\(uri)>]")
            }
        }
        if let structuredContent, !structuredContent.isNull {
            if lines.isEmpty {
                lines.append(structuredContent.description)
            } else {
                lines.append("[structured content: \(structuredContent.description)]")
            }
        }
        return lines.joined(separator: "\n")
    }
}
