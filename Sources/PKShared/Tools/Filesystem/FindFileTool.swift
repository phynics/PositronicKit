import Foundation
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

    public var parametersSchema: [String: AnyCodable] {
        ToolParameterSchema.object {
            JSONProperty(key: "path") {
                JSONString().description("The root directory to start searching (default: .)")
            }
            JSONProperty(key: "pattern") {
                JSONString().description("The filename pattern to match (contains check, case insensitive)")
            }
            .required()
            JSONProperty(key: "workspaceID") {
                JSONString().description("The UUID of the workspace to target (optional)")
            }
        }.schema
    }

    public func execute(parameters: [String: Any]) async throws -> ToolResult {
        let params = ToolParameters(parameters)
        let pattern: String
        do {
            pattern = try params.require("pattern", as: String.self)
        } catch {
            let errorMsg = error.localizedDescription
            if let example = usageExample {
                return .failure("\(errorMsg) Example: \(example)")
            }
            return .failure(errorMsg)
        }

        let pathString = params.optional("path", as: String.self) ?? "."
        let url: URL
        do {
            url = try PathSanitizer.safelyResolve(path: pathString, within: currentDirectory, jailRoot: jailRoot)
        } catch {
            return .failure(error.localizedDescription)
        }

        let fileManager = FileManager.default

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return .failure("Path not found: \(pathString)")
        }

        guard isDirectory.boolValue else {
            return .failure("Path is not a directory: \(pathString)")
        }

        var matches: [String] = []
        let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        while let fileURL = enumerator?.nextObject() as? URL {
            if fileURL.lastPathComponent.localizedCaseInsensitiveContains(pattern) {
                // Return relative path if possible, or full path
                let path = fileURL.path.replacingOccurrences(of: url.path, with: "")
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                matches.append(path.isEmpty ? fileURL.lastPathComponent : path)
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
