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
            JSONProperty(key: "workspaceID") {
                JSONString().description("The UUID of the workspace to target (optional)")
            }
        }.schema
    }

    public func execute(parameters: [String: Any]) async throws -> ToolResult {
        let params = ToolParameters(parameters)
        let pathString = params.optional("path", as: String.self) ?? "."

        let url: URL
        do {
            url = try PathSanitizer.safelyResolve(path: pathString, within: currentDirectory, jailRoot: jailRoot)
        } catch {
            return .failure(error.localizedDescription)
        }

        let fileManager = FileManager.default

        do {
            // Check if path exists and is a directory
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                return .failure("Path not found: \(pathString)")
            }

            guard isDirectory.boolValue else {
                return .failure("Path is not a directory: \(pathString)")
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
