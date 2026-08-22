import Foundation
import struct JSONSchema.Schema
import PKContracts
import PKUtilities

/// Generic filesystem tools exposed only by an Agent's primary workspace.
///
/// The tools deliberately sit on the capability boundary (`WorkspaceFileProvider`) so hosts can
/// back an Agent workspace with a remote or database implementation. The bundled provider is a
/// jailed local adapter used when a persisted workspace has a filesystem root but no registered
/// provider.
struct AgentWorkspaceFileTool: Tool, Sendable {
    private static let maxReadBytes = 256 * 1_024
    fileprivate static let maxWriteBytes = 1_024 * 1_024
    private static let maxListedOutputBytes = 128 * 1_024
    private static let maxSearchLineBytes = 8 * 1_024

    enum Operation: String, Sendable {
        case readFile = "read_file"
        case listFiles = "list_files"
        case searchFiles = "search_files"
        case writeFile = "write_file"
        case appendFile = "append_file"
        case editFile = "edit_file"
        case deleteFile = "delete_file"

        var displayName: String {
            switch self {
            case .readFile: "Read File"
            case .listFiles: "List Files"
            case .searchFiles: "Search Files"
            case .writeFile: "Write File"
            case .appendFile: "Append File"
            case .editFile: "Edit File"
            case .deleteFile: "Delete File"
            }
        }

        var mutates: Bool {
            switch self {
            case .writeFile, .appendFile, .editFile, .deleteFile: true
            case .readFile, .listFiles, .searchFiles: false
            }
        }
    }

    let operation: Operation
    let provider: any WorkspaceFileProvider

    var callName: String { operation.rawValue }
    var name: String { operation.displayName }
    var description: String {
        switch operation {
        case .readFile: "Read a UTF-8 file using a path relative to the Agent workspace root."
        case .listFiles: "List files below a path relative to the Agent workspace root."
        case .searchFiles: "Search file contents below a workspace path using a regular expression."
        case .writeFile: "Create or replace a UTF-8 file in the Agent workspace."
        case .appendFile: "Append text to a UTF-8 file in the Agent workspace."
        case .editFile: "Apply unique exact-text edits atomically to a workspace file."
        case .deleteFile: "Delete one regular file from the Agent workspace."
        }
    }
    let requiresPermission = false
    var sideEffects: ToolSideEffects { operation.mutates ? .mutating : .none }
    let usageExample: String? = nil

    init(operation: Operation, provider: any WorkspaceFileProvider) {
        self.operation = operation
        self.provider = provider
    }

    func requiresPermission(for parameters: [String: AnyCodable]) -> Bool {
        guard operation.mutates, let path = parameters["path"]?.asString else { return false }
        guard let normalized = Self.normalizedRelativePath(path) else { return false }
        guard normalized.caseInsensitiveCompare("SOUL.md") != .orderedSame else { return true }

        // Approval is based on the file ultimately addressed, not merely the spelling supplied
        // by the model. Local providers resolve symlinks and case-insensitive filesystems can
        // spell the same root file differently; both must still be treated as SOUL.md.
        // A provider without a local root cannot prove that an alias resolves elsewhere, so keep
        // the conservative approval gate for every mutation on remote/custom backends.
        guard let rootPath = provider.reference.rootPath else { return true }
        let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
        let candidate = rootURL.appendingPathComponent(normalized)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
        let soul = rootURL.appendingPathComponent("SOUL.md")
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
        return candidate.caseInsensitiveCompare(soul) == .orderedSame
    }

    var parametersSchema: Schema {
        let path: AnyCodable = .dictionary(["type": .string("string")])
        switch operation {
        case .readFile, .deleteFile:
            return Schema(objectSchema(properties: ["path": path], required: ["path"]))
        case .listFiles:
            return Schema(objectSchema(properties: ["path": path], required: []))
        case .searchFiles:
            return Schema(objectSchema(properties: [
                "pattern": .dictionary(["type": .string("string")]),
                "path": path,
            ], required: ["pattern"]))
        case .writeFile, .appendFile:
            return Schema(objectSchema(properties: [
                "path": path,
                "content": .dictionary(["type": .string("string")]),
            ], required: ["path", "content"]))
        case .editFile:
            let edit = AnyCodable.dictionary([
                "type": .string("object"),
                "properties": .dictionary([
                    "oldText": .dictionary(["type": .string("string")]),
                    "newText": .dictionary(["type": .string("string")]),
                ]),
                "required": .array([.string("oldText"), .string("newText")]),
                "additionalProperties": .boolean(false),
            ])
            return Schema(objectSchema(properties: [
                "path": path,
                "edits": .dictionary([
                    "type": .string("array"),
                    "items": edit,
                ]),
            ], required: ["path", "edits"]))
        }
    }

    func canExecute() async -> Bool {
        await provider.healthCheck()
    }

    func execute(parameters: [String: AnyCodable]) async throws -> ToolResult {
        do {
            switch operation {
            case .readFile:
                let path = try requiredString("path", parameters)
                let content = try await provider.readFile(path: validated(path))
                return .success(boundedOutput(content, byteCount: Self.maxReadBytes))
            case .listFiles:
                let path = parameters["path"]?.asString ?? "."
                let files = try await provider.listFiles(path: validated(path))
                return .success(boundedOutput(files.sorted().prefix(500).joined(separator: "\n"), byteCount: Self.maxListedOutputBytes))
            case .searchFiles:
                let pattern = try requiredString("pattern", parameters)
                let path = parameters["path"]?.asString ?? "."
                return try await search(pattern: pattern, path: validated(path))
            case .writeFile:
                let path = try requiredString("path", parameters)
                let content = try requiredString("content", parameters)
                try validateWriteContent(content)
                try await provider.writeFile(path: validated(path), content: content)
                return .success("Wrote \(path)")
            case .appendFile:
                let path = try requiredString("path", parameters)
                let content = try requiredString("content", parameters)
                let safePath = try validated(path)
                let existing = (try? await provider.readFile(path: safePath)) ?? ""
                try validateWriteContent(existing + content)
                try await provider.writeFile(path: safePath, content: existing + content)
                return .success("Appended to \(path)")
            case .editFile:
                let path = try requiredString("path", parameters)
                let edits = try decodeEdits(parameters["edits"])
                let safePath = try validated(path)
                let original = try await provider.readFile(path: safePath)
                let updated = try apply(edits, to: original)
                try validateWriteContent(updated)
                try await provider.writeFile(path: safePath, content: updated)
                return .success("Edited \(path) (\(edits.count) change\(edits.count == 1 ? "" : "s"))")
            case .deleteFile:
                let path = try requiredString("path", parameters)
                try await provider.deleteFile(path: validated(path))
                return .success("Deleted \(path)")
            }
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    private func search(pattern: String, path: String) async throws -> ToolResult {
        let regex = try NSRegularExpression(pattern: pattern)
        let files = try await provider.listFiles(path: path).sorted()
        var matches: [String] = []
        for file in files.prefix(200) {
            guard let content = try? await provider.readFile(path: file) else { continue }
            let boundedContent = boundedOutput(content, byteCount: Self.maxReadBytes)
            for (lineIndex, line) in boundedContent.components(separatedBy: .newlines).enumerated()
                where regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
            {
                matches.append("\(file):\(lineIndex + 1): \(boundedOutput(line, byteCount: Self.maxSearchLineBytes))")
                if matches.count == 100 { return .success(matches.joined(separator: "\n")) }
            }
        }
        return .success(matches.joined(separator: "\n"))
    }

    private func requiredString(_ key: String, _ parameters: [String: AnyCodable]) throws -> String {
        guard let value = parameters[key]?.asString, !value.isEmpty else {
            throw ToolError.missingArgument(key)
        }
        return value
    }

    private func validateWriteContent(_ content: String) throws {
        guard content.utf8.count <= Self.maxWriteBytes else {
            throw ToolError.invalidArgument("content", expected: "at most \(Self.maxWriteBytes) UTF-8 bytes", got: "\(content.utf8.count) bytes")
        }
    }

    private func boundedOutput(_ content: String, byteCount: Int) -> String {
        let bounded = utf8Prefix(of: content, byteCount: byteCount)
        return bounded.utf8.count == content.utf8.count ? bounded : bounded + "\n[output truncated]"
    }

    private func validated(_ path: String) throws -> String {
        guard let normalized = Self.normalizedRelativePath(path) else {
            throw WorkspaceError.accessDenied
        }
        return normalized.isEmpty ? "." : normalized
    }

    private static func normalizedRelativePath(_ path: String) -> String? {
        guard !path.hasPrefix("/"), !path.hasPrefix("~") else { return nil }
        let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !components.contains("..") else { return nil }
        return components.filter { $0 != "." }.joined(separator: "/")
    }

    private struct Edit: Sendable {
        let oldText: String
        let newText: String
    }

    private func decodeEdits(_ value: AnyCodable?) throws -> [Edit] {
        guard let entries = value?.asArray, !entries.isEmpty else {
            throw ToolError.invalidArgument("edits", expected: "a non-empty array", got: value?.description ?? "missing")
        }
        return try entries.map { entry in
            guard let dictionary = entry.asDictionary,
                  let oldText = dictionary["oldText"]?.asString,
                  let newText = dictionary["newText"]?.asString
            else {
                throw ToolError.invalidArgument("edits", expected: "objects with oldText and newText", got: entry.description)
            }
            return Edit(oldText: oldText, newText: newText)
        }
    }

    private func apply(_ edits: [Edit], to original: String) throws -> String {
        let hasBOM = original.hasPrefix("\u{FEFF}")
        let normalized = (hasBOM ? String(original.dropFirst()) : original).replacingOccurrences(of: "\r\n", with: "\n")
        var replacements: [(range: NSRange, text: String)] = []
        for edit in edits {
            guard let foundRange = uniqueMatchRange(for: edit.oldText, in: normalized) else {
                throw WorkspaceError.invalidWorkspaceType
            }
            let range = NSRange(foundRange, in: normalized)
            replacements.append((range, edit.newText))
        }
        let sorted = replacements.sorted { $0.range.location < $1.range.location }
        for pair in zip(sorted, sorted.dropFirst()) where NSMaxRange(pair.0.range) > pair.1.range.location {
            throw WorkspaceError.invalidWorkspaceType
        }
        var updated = normalized as NSString
        for replacement in replacements.sorted(by: { $0.range.location > $1.range.location }) {
            updated = updated.replacingCharacters(in: replacement.range, with: replacement.text) as NSString
        }
        var output = updated as String
        if original.contains("\r\n") { output = output.replacingOccurrences(of: "\n", with: "\r\n") }
        return (hasBOM ? "\u{FEFF}" : "") + output
    }

    private func uniqueMatchRange(for needle: String, in haystack: String) -> Range<String.Index>? {
        guard !needle.isEmpty else { return nil }
        var searchStart = haystack.startIndex
        var match: Range<String.Index>?
        var count = 0
        while searchStart < haystack.endIndex,
              let candidate = haystack.range(of: needle, range: searchStart..<haystack.endIndex)
        {
            count += 1
            if count > 1 { return nil }
            match = candidate
            searchStart = haystack.index(after: candidate.lowerBound)
        }
        return count == 1 ? match : nil
    }

    private func objectSchema(properties: [String: AnyCodable], required: [String]) -> [String: AnyCodable] {
        [
            "type": .string("object"),
            "properties": .dictionary(properties),
            "required": .array(required.map(AnyCodable.string)),
            "additionalProperties": .boolean(false),
        ]
    }

    private func utf8Prefix(of content: String, byteCount: Int) -> String {
        guard byteCount > 0 else { return "" }
        var output = ""
        var used = 0
        for character in content {
            guard used + character.utf8.count <= byteCount else { break }
            output.append(character)
            used += character.utf8.count
        }
        return output
    }
}

/// Jailed local adapter for an Agent workspace reference.
actor LocalAgentWorkspaceProvider: WorkspaceFileProvider {
    nonisolated let reference: WorkspaceReference
    private let rootURL: URL

    init(reference: WorkspaceReference) throws {
        guard let rootPath = reference.rootPath else { throw WorkspaceError.invalidWorkspaceType }
        self.reference = reference
        rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
    }

    func healthCheck() async -> Bool {
        FileManager.default.fileExists(atPath: rootURL.path)
    }

    func readFile(path: String) async throws -> String {
        let url = try resolve(path)
        if let fileSize = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           fileSize > AgentWorkspaceFileTool.maxWriteBytes
        {
            throw WorkspaceError.invalidWorkspaceType
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    func writeFile(path: String, content: String) async throws {
        let url = try resolve(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    func listFiles(path: String) async throws -> [String] {
        let url = try resolve(path)
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        let root = rootURL.resolvingSymlinksInPath().path
        var output: [String] = []
        while let candidate = enumerator.nextObject() as? URL {
            guard (try? candidate.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let resolved = candidate.resolvingSymlinksInPath().path
            guard resolved == root || resolved.hasPrefix(root + "/") else { throw WorkspaceError.accessDenied }
            output.append(String(resolved.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/")))
            if output.count == 500 { break }
        }
        return output
    }

    func deleteFile(path: String) async throws {
        let url = try resolve(path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw WorkspaceError.invalidWorkspaceType
        }
        try FileManager.default.removeItem(at: url)
    }

    private func resolve(_ path: String) throws -> URL {
        try PathSanitizer.safelyResolve(path: path, within: rootURL.path, jailRoot: rootURL.path)
    }
}

extension AgentWorkspaceFileTool.Operation {
    static let all: [Self] = [.readFile, .listFiles, .searchFiles, .writeFile, .appendFile, .editFile, .deleteFile]
}
