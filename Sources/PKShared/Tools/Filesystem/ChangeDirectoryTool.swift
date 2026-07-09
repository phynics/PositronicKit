import Foundation
import struct JSONSchema.Schema
import JSONSchemaBuilder

/// Tool to change the current working directory of the session
public struct ChangeDirectoryTool: Tool, Sendable {
    public let id = "change_directory"
    public let name = "Change Directory"
    public let description = "Change the current working directory for relative file operations."
    public let requiresPermission = false

    public var usageExample: String? {
        """
        <tool_call>
        {"name": "change_directory", "arguments": {"path": "Sources/PositronicKit"}}
        </tool_call>
        """
    }

    private let onChange: @Sendable (String) async -> Void
    private let root: String

    public init(currentPath: String, root: String? = nil, onChange: @escaping @Sendable (String) async -> Void) {
        self.root = root ?? currentPath
        self.onChange = onChange
    }

    public func canExecute() async -> Bool {
        return true
    }

    public var parametersSchema: Schema {
        ToolParameterSchema.object {
            JSONProperty(key: "path") {
                JSONString().description("The path to change to. Can be relative or absolute.")
            }
            .required()
        }.schemaDefinition
    }

    public func execute(parameters: [String: AnyCodable]) async throws -> ToolResult {
        let params = ToolParameters(parameters)
        let path: String
        do {
            path = try params.require("path", as: String.self)
        } catch {
            return .failure(error.localizedDescription)
        }

        let newURL: URL
        do {
            newURL = try PathSanitizer.safelyResolve(path: path, within: root)
        } catch {
            return .failure(error.localizedDescription)
        }

        let newPath = newURL.path
        let fileManager = FileManager.default

        // Validate existence and is directory
        var isDir: ObjCBool = false
        if fileManager.fileExists(atPath: newPath, isDirectory: &isDir) {
            if isDir.boolValue {
                await onChange(newPath)
                return .success("Changed directory to \(newPath)")
            } else {
                return .failure("Path exists but is not a directory: \(newPath)")
            }
        } else {
            return .failure("Directory not found: \(newPath)")
        }
    }
}
