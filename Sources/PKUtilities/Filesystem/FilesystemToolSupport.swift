import PKShared
import Foundation

enum FilesystemToolSupport {
    enum StringRequirement {
        case success(String)
        case failure(ToolResult)
    }

    enum URLResolution {
        case success(URL)
        case failure(ToolResult)
    }

    enum Validation {
        case success
        case failure(ToolResult)
    }

    static func requiredString(
        _ key: String,
        from params: ToolParameters,
        usageExample: String?
    ) -> StringRequirement {
        do {
            return try .success(params.require(key, as: String.self))
        } catch {
            let errorMessage = error.localizedDescription
            if let usageExample {
                return .failure(.failure("\(errorMessage) Example: \(usageExample)"))
            }
            return .failure(.failure(errorMessage))
        }
    }

    static func resolvePath(
        _ pathString: String,
        currentDirectory: String,
        jailRoot: String
    ) -> URLResolution {
        do {
            return try .success(PathSanitizer.safelyResolve(
                path: pathString,
                within: currentDirectory,
                jailRoot: jailRoot
            ))
        } catch {
            return .failure(.failure(error.localizedDescription))
        }
    }

    static func requireExistingDirectory(
        at url: URL,
        displayPath: String
    ) -> Validation {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false

        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return .failure(.failure("Path not found: \(displayPath). \(pathNotFoundHint)"))
        }

        guard isDirectory.boolValue else {
            return .failure(.failure("Path is not a directory: \(displayPath). Pass a directory path, or use `cat` to read a file."))
        }

        return .success
    }

    static func requireExistingPath(
        at url: URL,
        displayPath: String
    ) -> Validation {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .failure(.failure("Path not found: \(displayPath). \(pathNotFoundHint)"))
        }

        return .success
    }

    static func requireExistingFile(
        at url: URL,
        displayPath: String
    ) -> Validation {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false

        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return .failure(.failure("File not found: \(displayPath). \(pathNotFoundHint)"))
        }

        guard !isDirectory.boolValue else {
            return .failure(.failure("Path is not a file: \(displayPath). This is a directory — use `ls` to list its contents."))
        }

        return .success
    }

    /// Shared recovery hint appended to "not found" failures. Paths resolve relative to the
    /// workspace root, so the most common fix is locating the correct path first.
    static let pathNotFoundHint =
        "Paths are resolved relative to the workspace root — check the path, or use `ls`/`find` to locate it first."

    static func relativeDisplayPath(for url: URL, baseURL: URL) -> String {
        let relativePath = url.path
            .replacingOccurrences(of: baseURL.path, with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return relativePath.isEmpty ? url.lastPathComponent : relativePath
    }

    static func limitedOutput(
        _ lines: [String],
        limit: Int,
        suffix: String = "... (limit reached)"
    ) -> String {
        guard lines.count > limit else {
            return lines.joined(separator: "\n")
        }
        return lines.prefix(limit).joined(separator: "\n") + "\n" + suffix
    }
}
