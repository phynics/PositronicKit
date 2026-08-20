import PKContracts
import Foundation
import struct JSONSchema.Schema
import JSONSchemaBuilder

/// Tool to read file content (cat)
package struct ReadFileTool: Tool, Sendable {
    package let callName = "cat"
    package let name = "Read File"
    package let description = "Read the content of a file"
    package let requiresPermission = true

    package var usageExample: String? {
        """
        <tool_call>
        {"name": "cat", "arguments": {"path": "Sources/main.swift"}}
        </tool_call>
        """
    }

    private let currentDirectory: String
    private let jailRoot: String

    package init(
        currentDirectory: String = FileManager.default.currentDirectoryPath,
        jailRoot: String? = nil
    ) {
        self.currentDirectory = currentDirectory
        self.jailRoot = jailRoot ?? currentDirectory
    }

    package func canExecute() async -> Bool {
        return true
    }

    package var parametersSchema: Schema {
        ToolParameterSchema.object {
            JSONProperty(key: "path") {
                JSONString().description("The path to the file to read")
            }
            .required()
        }.schemaDefinition
    }

    package func execute(parameters: [String: AnyCodable]) async throws -> ToolResult {
        let params = ToolParameters(parameters)
        let pathString: String
        switch FilesystemToolSupport.requiredString("path", from: params, usageExample: usageExample) {
        case .success(let value):
            pathString = value
        case .failure(let result):
            return result
        }

        let url: URL
        switch FilesystemToolSupport.resolvePath(pathString, currentDirectory: currentDirectory, jailRoot: jailRoot) {
        case .success(let value):
            url = value
        case .failure(let result):
            return result
        }

        switch FilesystemToolSupport.requireExistingFile(at: url, displayPath: pathString) {
        case .success:
            break
        case .failure(let result):
            return result
        }

        let fileManager = FileManager.default

        do {
            // Check file size to prevent reading massive files accidentally
            let attr = try fileManager.attributesOfItem(atPath: url.path)
            let size = attr[.size] as? Int64 ?? 0

            if size > 1_000_000 { // 1MB limit for raw cat
                return .failure(
                    "File is too large (\(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))). " +
                        "Please use document tools to load it as context."
                )
            }

            let content = try String(contentsOf: url, encoding: .utf8)
            return .success(content)
        } catch {
            return .failure("Failed to read file: \(error.localizedDescription)")
        }
    }
}
