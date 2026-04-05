import MonadShared
import MonadCore
import Foundation

/// A minimal mock workspace for unit testing, backed by a temp directory.
public actor MockLocalWorkspace: WorkspaceProtocol {
    public let reference: WorkspaceReference
    public nonisolated let id: UUID
    private let rootURL: URL

    public init(rootURL: URL) {
        let ref = WorkspaceReference(
            uri: WorkspaceURI(host: "monad-server", path: rootURL.path),
            hostType: .server,
            rootPath: rootURL.path
        )
        self.reference = ref
        self.id = ref.id
        self.rootURL = rootURL
    }

    public init(reference: WorkspaceReference) throws {
        guard let path = reference.rootPath else { throw WorkspaceError.invalidWorkspaceType }
        self.reference = reference
        self.id = reference.id
        self.rootURL = URL(fileURLWithPath: path)
    }

    public func listTools() async throws -> [ToolReference] { return reference.tools }

    public func executeTool(id: String, parameters: [String: AnyCodable]) async throws -> ToolResult {
        throw WorkspaceError.toolExecutionNotSupported
    }

    public func readFile(path: String) async throws -> String {
        let url = rootURL.appendingPathComponent(path)
        return try String(contentsOf: url, encoding: .utf8)
    }

    public func writeFile(path: String, content: String) async throws {
        let url = rootURL.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    public func listFiles(path: String) async throws -> [String] {
        let target = rootURL.appendingPathComponent(path)
        guard let enumerator = FileManager.default.enumerator(at: target, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else {
            return []
        }
        var files: [String] = []
        let rootPath = rootURL.resolvingSymlinksInPath().path
        while let fileURL = enumerator.nextObject() as? URL {
            let rv = try? fileURL.resourceValues(forKeys: [.isRegularFileKey])
            if rv?.isRegularFile == true {
                let fp = fileURL.resolvingSymlinksInPath().path
                if fp.hasPrefix(rootPath) {
                    files.append(String(fp.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/")))
                }
            }
        }
        return files
    }

    public func deleteFile(path: String) async throws {
        let url = rootURL.appendingPathComponent(path)
        try FileManager.default.removeItem(at: url)
    }

    public func healthCheck() async -> Bool {
        return FileManager.default.fileExists(atPath: rootURL.path)
    }
}

public struct MockWorkspaceCreator: WorkspaceCreating {
    public init() {}
    public func create(from reference: WorkspaceReference, connectionManager: (any ClientConnectionManagerProtocol)?) throws -> any WorkspaceProtocol {
        return try MockLocalWorkspace(reference: reference)
    }
}
