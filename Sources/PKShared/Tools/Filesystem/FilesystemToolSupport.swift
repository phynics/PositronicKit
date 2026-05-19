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
            return .success(try params.require(key, as: String.self))
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
            return .success(try PathSanitizer.safelyResolve(
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
            return .failure(.failure("Path not found: \(displayPath)"))
        }

        guard isDirectory.boolValue else {
            return .failure(.failure("Path is not a directory: \(displayPath)"))
        }

        return .success
    }

    static func requireExistingPath(
        at url: URL,
        displayPath: String
    ) -> Validation {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .failure(.failure("Path not found: \(displayPath)"))
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
            return .failure(.failure("File not found: \(displayPath)"))
        }

        guard !isDirectory.boolValue else {
            return .failure(.failure("Path is not a file: \(displayPath)"))
        }

        return .success
    }

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
