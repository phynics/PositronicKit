import Foundation
import JSONSchemaBuilder

/// Tool to inspect file metadata and type (similar to unix 'file' command)
public struct InspectFileTool: Tool, Sendable {
    public let id = "inspect_file"
    public let name = "Inspect File"
    public let description = "Determine file type and basic metadata using the unix 'file' command."
    public let requiresPermission = false // Inspection is usually safe

    public var usageExample: String? {
        """
        <tool_call>
        {"name": "inspect_file", "arguments": {"path": "Sources/main.swift"}}
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
                JSONString().description("The path to the file to inspect")
            }
            .required()
            JSONProperty(key: "workspaceID") {
                JSONString().description("The UUID of the workspace to target (optional)")
            }
        }.schema
    }

    public func execute(parameters: [String: Any]) async throws -> ToolResult {
        let params = ToolParameters(parameters)
        let pathString: String
        do {
            pathString = try params.require("path", as: String.self)
        } catch {
            let errorMsg = error.localizedDescription
            if let example = usageExample {
                return .failure("\(errorMsg) Example: \(example)")
            }
            return .failure(errorMsg)
        }

        let url: URL
        do {
            url = try PathSanitizer.safelyResolve(path: pathString, within: currentDirectory, jailRoot: jailRoot)
        } catch {
            return .failure(error.localizedDescription)
        }

        guard FileManager.default.fileExists(atPath: url.path) else {
            return .failure("File not found: \(pathString)")
        }

        return runFileCommand(at: url)
    }

    private func runFileCommand(at url: URL) -> ToolResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/file")
        process.arguments = [url.path]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe

        let errorPipe = Pipe()
        process.standardError = errorPipe

        do {
            try process.run()
            process.waitUntilExit()

            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

            if process.terminationStatus == 0 {
                let output =
                    String(data: outputData, encoding: .utf8)?.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ) ?? "No output"
                return .success(output)
            } else {
                let errorOutput =
                    String(data: errorData, encoding: .utf8)?.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ) ?? "Unknown error"
                return .failure(
                    "File command failed with status \(process.terminationStatus): \(errorOutput)"
                )
            }
        } catch {
            return .failure("Failed to execute file command: \(error.localizedDescription)")
        }
    }
}
