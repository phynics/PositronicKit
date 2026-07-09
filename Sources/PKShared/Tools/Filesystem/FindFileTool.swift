import Foundation
import struct JSONSchema.Schema
import JSONSchemaBuilder

/// Tool to find files matching a pattern
public struct FindFileTool: Tool, Sendable {
    public let id = "find"
    public let name = "Find File"
    public let description = "Find files matching a pattern in a directory recursively"
    public let requiresPermission = true

    public var usageExample: String? {
        """
        <tool_call>
        {\"name\": \"find\", \"arguments\": {\"path\": \".\", \"pattern\": \"Podfile\"}}
        </tool_call>
        """
    }

    private let currentDirectory: String
    private let jailRoot: String

    public init(
        currentDirectory: String = FileManager.default.currentDirectoryPath,
        jailRoot: String? = nil
    ) {
        self.currentDirectory = currentDirectory
        self.jailRoot = jailRoot ?? currentDirectory
    }

    public func canExecute() async -> Bool {
        return true
    }

    public var parametersSchema: Schema {
        ToolParameterSchema.object {
            JSONProperty(key: "path") {
                JSONString().description("The root directory to start searching (default: .)")
            }
            JSONProperty(key: "pattern") {
                JSONString().description("The filename pattern to match (contains check, case insensitive)")
            }
            .required()
        }.schemaDefinition
    }

    public func execute(parameters: [String: AnyCodable]) async throws -> ToolResult {
        let params = ToolParameters(parameters)
        let pattern: String
        switch FilesystemToolSupport.requiredString("pattern", from: params, usageExample: usageExample) {
        case .success(let value):
            pattern = value
        case .failure(let result):
            return result
        }

        let pathString = params.optional("path", as: String.self) ?? "."
        let url: URL
        switch FilesystemToolSupport.resolvePath(pathString, currentDirectory: currentDirectory, jailRoot: jailRoot) {
        case .success(let value):
            url = value
        case .failure(let result):
            return result
        }

        switch FilesystemToolSupport.requireExistingDirectory(at: url, displayPath: pathString) {
        case .success:
            break
        case .failure(let result):
            return result
        }

        let fileManager = FileManager.default

        var matches: [String] = []
        let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        while let fileURL = enumerator?.nextObject() as? URL {
            if fileURL.lastPathComponent.localizedCaseInsensitiveContains(pattern) {
                matches.append(FilesystemToolSupport.relativeDisplayPath(for: fileURL, baseURL: url))
            }

            // Limit results to prevent massive outputs
            if matches.count >= 100 {
                matches.append("... (limit reached)")
                break
            }
        }

        if matches.isEmpty {
            return .success("No files found matching '\(pattern)' in \(pathString)")
        }

        return .success(matches.sorted().joined(separator: "\n"))
    }
}
