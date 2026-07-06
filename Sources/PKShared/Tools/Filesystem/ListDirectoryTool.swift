import Foundation
import JSONSchemaBuilder

/// Tool to list files in a directory
public struct ListDirectoryTool: Tool, Sendable {
    public let id = "ls"
    public let name = "List Directory"
    public let description = "List files and directories at a specific path"
    public let requiresPermission = true

    public var usageExample: String? {
        """
        <tool_call>
        {\"name\": \"ls\", \"arguments\": {\"path\": \"/Users/username/Projects\"}}
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

    public var parametersSchema: [String: AnyCodable] {
        ToolParameterSchema.object {
            JSONProperty(key: "path") {
                JSONString().description("The path to the directory (defaults to current directory if omitted)")
            }
        }.schema
    }

    public func execute(parameters: [String: Any]) async throws -> ToolResult {
        let params = ToolParameters(parameters)
        let pathString = params.optional("path", as: String.self) ?? "."

        let url: URL
        switch FilesystemToolSupport.resolvePath(pathString, currentDirectory: currentDirectory, jailRoot: jailRoot) {
        case .success(let value):
            url = value
        case .failure(let result):
            return result
        }

        let fileManager = FileManager.default

        do {
            switch FilesystemToolSupport.requireExistingDirectory(at: url, displayPath: pathString) {
            case .success:
                break
            case .failure(let result):
                return result
            }

            let contents = try fileManager.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            )

            let formattedContents = contents.map { fileURL -> String in
                let name = fileURL.lastPathComponent
                let isDir =
                    (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0

                let typeMarker = isDir ? "[DIR]" : "[FILE]"
                let sizeString =
                    isDir
                        ? "" : ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)

                return "\(typeMarker) \(name) \(sizeString)".trimmingCharacters(in: .whitespaces)
            }.sorted()

            return .success(formattedContents.joined(separator: "\n"))

        } catch {
            return .failure("Failed to list directory: \(error.localizedDescription)")
        }
    }
}
