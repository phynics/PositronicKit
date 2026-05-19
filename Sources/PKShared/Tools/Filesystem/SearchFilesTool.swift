import Foundation
import JSONSchemaBuilder

/// Enhanced tool to search text content in files (search_files)
public struct SearchFilesTool: Tool, Sendable {
    public let id = "search_files"
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
            JSONProperty(key: "workspaceID") {
                JSONString().description("The UUID of the workspace to target (optional)")
            }
        }.schema
    }

    public func execute(parameters: [String: Any]) async throws -> ToolResult {
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

        return runGrepSearch(pattern: pattern, searchURL: url, includePattern: includePattern)
    }

    private func runGrepSearch(pattern: String, searchURL: URL, includePattern: String?) -> ToolResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/grep")

        var arguments = ["-rn", "--exclude-dir=.git", "--exclude-dir=.build"]
        if let include = includePattern {
            arguments.append("--include=\(include)")
        }
        arguments.append(pattern)
        arguments.append(searchURL.path)
        process.arguments = arguments

        let outputPipe = Pipe()
        process.standardOutput = outputPipe

        let errorPipe = Pipe()
        process.standardError = errorPipe

        do {
            try process.run()
            process.waitUntilExit()

            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

            if process.terminationStatus == 0 || process.terminationStatus == 1 {
                let output = String(data: outputData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if output.isEmpty {
                    return .success("No matches found for '\(pattern)'")
                }

                let lines = output.components(separatedBy: .newlines)
                return .success(FilesystemToolSupport.limitedOutput(lines, limit: 100))
            } else {
                let errorOutput = String(data: errorData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? "Unknown error"
                return .failure("Search failed with status \(process.terminationStatus): \(errorOutput)")
            }
        } catch {
            return .failure("Failed to execute search: \(error.localizedDescription)")
        }
    }
}
