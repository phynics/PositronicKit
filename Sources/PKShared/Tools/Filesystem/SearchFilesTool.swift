import Foundation
import struct JSONSchema.Schema
import JSONSchemaBuilder

/// Enhanced tool to search text content in files (search_files)
public struct SearchFilesTool: Tool, Sendable {
    public let callName = "search_files"
    public let name = "Search Files"
    public let description = "Optimized search for text content across files in the workspace."
    public let requiresPermission = true

    public var usageExample: String? {
        """
        <tool_call>
        {\"name\": \"search_files\", \"arguments\": {\"pattern\": \"TODO:\"}}
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
        self.limits = FilesystemSearchLimits()
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
            JSONProperty(key: "pattern") {
                JSONString().description("The text pattern to search for (regex supported)")
            }
            .required()
            JSONProperty(key: "path") {
                JSONString().description("The directory to search within (default: current directory)")
            }
            JSONProperty(key: "include") {
                JSONString().description("Optional glob pattern for files to include (e.g. '*.swift')")
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
        let includePattern = params.optional("include", as: String.self)

        let url: URL
        switch FilesystemToolSupport.resolvePath(pathString, currentDirectory: currentDirectory, jailRoot: jailRoot) {
        case .success(let value):
            url = value
        case .failure(let result):
            return result
        }

        switch FilesystemToolSupport.requireExistingPath(at: url, displayPath: pathString) {
        case .success:
            break
        case .failure(let result):
            return result
        }

        return searchFiles(pattern: pattern, searchURL: url, includePattern: includePattern)
    }

    private func searchFiles(pattern: String, searchURL: URL, includePattern: String?) -> ToolResult {
        do {
            let regex = try NSRegularExpression(pattern: pattern)
            var budget = FilesystemSearchBudget(limits: limits)
            var matches: [String] = []
            var limitReached = false

            try visitSearchFiles(at: searchURL) { fileURL, baseURL in
                try budget.checkProgress()
                guard shouldInclude(fileURL, includePattern: includePattern) else { return true }

                let displayPath = FilesystemToolSupport.relativeDisplayPath(for: fileURL, baseURL: baseURL)
                _ = try budget.reserveFile(fileURL, relativePath: displayPath)
                guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { return true }

                let lines = content.components(separatedBy: .newlines)
                for (index, line) in lines.enumerated() {
                    try budget.checkProgress()
                    let range = NSRange(line.startIndex..<line.endIndex, in: line)
                    guard regex.firstMatch(in: line, range: range) != nil else { continue }

                    let outputLine = "\(displayPath):\(index + 1):\(line)"
                    try budget.reserveOutput(outputLine)
                    matches.append(outputLine)
                    if matches.count >= limits.maxMatches {
                        limitReached = true
                        return false
                    }
                }
                return true
            }

            if matches.isEmpty {
                return .success("No matches found for '\(pattern)'")
            }
            let output = matches.joined(separator: "\n")
            return .success(limitReached ? output + "\n... (limit reached)" : output)
        } catch let failure as FilesystemSearchBudget.Failure {
            return .failure(failure.message)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain {
            return .failure("Invalid search pattern: \(error.localizedDescription)")
        } catch {
            return .failure("Search failed: \(error.localizedDescription)")
        }
    }

    private func visitSearchFiles(
        at url: URL,
        body: (URL, URL) throws -> Bool
    ) throws {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return }

        if !isDirectory.boolValue {
            _ = try body(url, url.deletingLastPathComponent())
            return
        }

        let options: FileManager.DirectoryEnumerationOptions = [
            .skipsHiddenFiles, .skipsPackageDescendants
        ]
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: options
        ) else {
            return
        }

        while let fileURL = enumerator.nextObject() as? URL {
            let lastPathComponent = fileURL.lastPathComponent
            if lastPathComponent == ".git" || lastPathComponent == ".build" {
                enumerator.skipDescendants()
                continue
            }

            var childIsDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: fileURL.path, isDirectory: &childIsDirectory),
                  !childIsDirectory.boolValue else {
                continue
            }

            if try !body(fileURL, url) {
                return
            }
        }
    }

    private func shouldInclude(_ fileURL: URL, includePattern: String?) -> Bool {
        guard let includePattern else { return true }
        return wildcard(includePattern, matches: fileURL.lastPathComponent)
    }

    private func wildcard(_ pattern: String, matches value: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: pattern)
            .replacingOccurrences(of: "\\*", with: ".*")
            .replacingOccurrences(of: "\\?", with: ".")
        return value.range(of: "^\(escaped)$", options: .regularExpression) != nil
    }
}
