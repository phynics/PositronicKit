import Foundation
import JSONSchemaBuilder

/// Tool to search text content in files (grep-like)
public struct SearchFileContentTool: Tool, Sendable {
    public let id = "grep"
    public let name = "Search File Content"
    public let description = "Search for text content within files in a directory"
    public let requiresPermission = true

    public var usageExample: String? {
        """
        <tool_call>
        {\"name\": \"grep\", \"arguments\": {\"path\": \"Sources\", \"pattern\": \"struct User\", \"recursive\": true}}
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
                JSONString().description("The directory or file to search (default: .)")
            }
            JSONProperty(key: "pattern") {
                JSONString().description("The text pattern to search for")
            }
            .required()
            JSONProperty(key: "recursive") {
                JSONBoolean().description("Whether to search recursively (default: false)")
            }
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
        let recursive = params.optional("recursive", as: Bool.self) ?? false

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

        let matches: [String]
        if isDirectory.boolValue {
            matches = searchDirectory(at: url, pattern: pattern, recursive: recursive)
        } else {
            matches = searchSingleFile(at: url, baseURL: url, pattern: pattern)
        }

        return formatSearchResults(matches, pattern: pattern)
    }

    // MARK: - Search Helpers

    private func searchDirectory(at url: URL, pattern: String, recursive: Bool) -> [String] {
        let fileManager = FileManager.default
        var matches: [String] = []

        if recursive {
            let options: FileManager.DirectoryEnumerationOptions = [
                .skipsHiddenFiles, .skipsPackageDescendants
            ]
            if let enumerator = fileManager.enumerator(
                at: url, includingPropertiesForKeys: nil, options: options
            ) {
                while let fileURL = enumerator.nextObject() as? URL {
                    var isDir: ObjCBool = false
                    if fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDir),
                       !isDir.boolValue {
                        matches.append(contentsOf: searchSingleFile(at: fileURL, baseURL: url, pattern: pattern))
                    }
                    if matches.count >= 50 { break }
                }
            }
        } else {
            let contents = try? fileManager.contentsOfDirectory(
                at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            )
            for fileURL in contents ?? [] {
                var isDir: ObjCBool = false
                if fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDir),
                   !isDir.boolValue {
                    matches.append(contentsOf: searchSingleFile(at: fileURL, baseURL: url, pattern: pattern))
                }
            }
        }

        return matches
    }

    private func searchSingleFile(at fileURL: URL, baseURL: URL, pattern: String) -> [String] {
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }

        var results: [String] = []
        let lines = content.components(separatedBy: .newlines)
        for (index, line) in lines.enumerated() where line.localizedCaseInsensitiveContains(pattern) {
            let relativePath = fileURL.path.replacingOccurrences(of: baseURL.path, with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let displayPath = relativePath.isEmpty ? fileURL.lastPathComponent : relativePath
            results.append("\(displayPath):\(index + 1): \(line.trimmingCharacters(in: .whitespaces))")
        }
        return results
    }

    private func formatSearchResults(_ matches: [String], pattern: String) -> ToolResult {
        if matches.isEmpty {
            return .success("No matches found for '\(pattern)'")
        }

        return .success(
            matches.prefix(50).joined(separator: "\n")
                + (matches.count > 50 ? "\n... (limit reached)" : "")
        )
    }
}
