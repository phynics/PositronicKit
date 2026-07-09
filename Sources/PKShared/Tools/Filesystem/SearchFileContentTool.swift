import Foundation
import struct JSONSchema.Schema
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
    private let limits: FilesystemSearchLimits

    public init(
        currentDirectory: String = FileManager.default.currentDirectoryPath,
        jailRoot: String? = nil
    ) {
        self.currentDirectory = currentDirectory
        self.jailRoot = jailRoot ?? currentDirectory
        self.limits = FilesystemSearchLimits(maxMatches: 50)
    }

    init(
        currentDirectory: String = FileManager.default.currentDirectoryPath,
        jailRoot: String? = nil,
        limits: FilesystemSearchLimits
    ) {
        self.currentDirectory = currentDirectory
        self.jailRoot = jailRoot ?? currentDirectory
        self.limits = limits
    }

    public func canExecute() async -> Bool {
        return true
    }

    public var parametersSchema: Schema {
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
        let recursive = params.optional("recursive", as: Bool.self) ?? false

        let url: URL
        switch FilesystemToolSupport.resolvePath(pathString, currentDirectory: currentDirectory, jailRoot: jailRoot) {
        case .success(let value):
            url = value
        case .failure(let result):
            return result
        }

        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false

        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return .failure("Path not found: \(pathString)")
        }

        do {
            var budget = FilesystemSearchBudget(limits: limits)
            let matches: [String]
            if isDirectory.boolValue {
                matches = try searchDirectory(at: url, pattern: pattern, recursive: recursive, budget: &budget)
            } else {
                matches = try searchSingleFile(at: url, baseURL: url.deletingLastPathComponent(), pattern: pattern, budget: &budget)
            }

            return formatSearchResults(matches, pattern: pattern)
        } catch let failure as FilesystemSearchBudget.Failure {
            return .failure(failure.message)
        } catch {
            return .failure("Search failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Search Helpers

    private func searchDirectory(
        at url: URL,
        pattern: String,
        recursive: Bool,
        budget: inout FilesystemSearchBudget
    ) throws -> [String] {
        let fileManager = FileManager.default
        var matches: [String] = []

        if recursive {
            let options: FileManager.DirectoryEnumerationOptions = [
                .skipsHiddenFiles, .skipsPackageDescendants
            ]
            if let enumerator = fileManager.enumerator(
                at: url, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey], options: options
            ) {
                while let fileURL = enumerator.nextObject() as? URL {
                    try budget.checkProgress()
                    var isDir: ObjCBool = false
                    if fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDir),
                       !isDir.boolValue {
                        matches.append(contentsOf: try searchSingleFile(at: fileURL, baseURL: url, pattern: pattern, budget: &budget))
                    }
                    if !budget.hasMatchCapacity { break }
                }
            }
        } else {
            let contents = try? fileManager.contentsOfDirectory(
                at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            )
            for fileURL in contents ?? [] {
                try budget.checkProgress()
                var isDir: ObjCBool = false
                if fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDir),
                   !isDir.boolValue {
                    matches.append(contentsOf: try searchSingleFile(at: fileURL, baseURL: url, pattern: pattern, budget: &budget))
                }
                if !budget.hasMatchCapacity { break }
            }
        }

        return matches
    }

    private func searchSingleFile(
        at fileURL: URL,
        baseURL: URL,
        pattern: String,
        budget: inout FilesystemSearchBudget
    ) throws -> [String] {
        let displayPath = FilesystemToolSupport.relativeDisplayPath(for: fileURL, baseURL: baseURL)
        let fileBytes = try budget.reserveFile(fileURL, relativePath: displayPath)
        guard let data = try? Data(contentsOf: fileURL, options: [.mappedIfSafe]),
              data.count == fileBytes,
              let content = String(data: data, encoding: .utf8) else {
            return []
        }

        var results: [String] = []
        let lines = content.components(separatedBy: .newlines)
        for (index, line) in lines.enumerated() where line.localizedCaseInsensitiveContains(pattern) {
            let outputLine = "\(displayPath):\(index + 1): \(line.trimmingCharacters(in: .whitespaces))"
            try budget.reserveOutput(outputLine)
            results.append(outputLine)
            if !budget.hasMatchCapacity {
                break
            }
        }
        return results
    }

    private func formatSearchResults(_ matches: [String], pattern: String) -> ToolResult {
        if matches.isEmpty {
            return .success("No matches found for '\(pattern)'")
        }

        return .success(FilesystemToolSupport.limitedOutput(matches, limit: 50))
    }
}
