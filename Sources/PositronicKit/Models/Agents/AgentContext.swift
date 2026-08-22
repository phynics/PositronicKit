import Foundation
import ErrorKit
import PKContracts

/// Errors raised when an authoritative Agent context cannot be used for the admitted identity.
public enum AgentContextError: PKError, Equatable, Sendable {
    case identityMismatch(expected: UUID, actual: UUID)

    public var errorDomain: String { PKErrorDomain.context }

    public var errorCode: Int { 2001 }

    public var userFriendlyMessage: String {
        "The Agent context source returned context for a different Agent."
    }

    public var errorDescription: String? {
        switch self {
        case let .identityMismatch(expected, actual):
            return "Agent context identity mismatch: expected \(expected), received \(actual)."
        }
    }
}

/// The identity portion of the typed context supplied to a managed Turn.
public struct AgentContextIdentity: Codable, Equatable, Hashable, Sendable {
    public let agentID: UUID
    public let name: String
    public let description: String

    public init(agentID: UUID, name: String, description: String) {
        self.agentID = agentID
        self.name = name
        self.description = description
    }
}

/// A bounded continuity item supplied by an ``AgentContextSource``.
public struct AgentContextMemory: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let content: String
    public let source: String?
    public let relevance: Double?

    public init(
        id: UUID = UUID(),
        content: String,
        source: String? = nil,
        relevance: Double? = nil
    ) {
        self.id = id
        self.content = content
        self.source = source
        self.relevance = relevance
    }
}

/// A discoverable Markdown resource in an Agent's primary workspace.
///
/// The catalog is intentionally metadata-only. The file remains on disk and is read through the
/// Agent workspace file tools when the model needs its full contents.
public struct AgentContextResource: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let id: String
    public let path: String
    public let description: String

    public init(path: String, description: String) {
        self.id = path
        self.path = path
        self.description = description
    }
}

/// The immutable Agent continuity captured for one managed Turn.
///
/// The runtime owns the reserved prompt section mapping. Sources return typed data rather
/// than arbitrary prompt nodes, so a host can replace filesystem storage with a database,
/// remote service, or a no-memory implementation without changing Turn orchestration.
public struct AgentContextSnapshot: Codable, Equatable, Sendable {
    public let identity: AgentContextIdentity
    public let instructions: String
    public let memories: [AgentContextMemory]
    public let resources: [AgentContextResource]
    public let diagnostics: [TurnDiagnostic]
    public let primaryThreadSummary: String?
    public let revision: String?

    public init(
        identity: AgentContextIdentity,
        instructions: String = "",
        memories: [AgentContextMemory] = [],
        resources: [AgentContextResource] = [],
        diagnostics: [TurnDiagnostic] = [],
        primaryThreadSummary: String? = nil,
        revision: String? = nil
    ) {
        self.identity = identity
        self.instructions = instructions
        self.memories = memories
        self.resources = resources
        self.diagnostics = diagnostics
        self.primaryThreadSummary = primaryThreadSummary
        self.revision = revision
    }

    public init(
        agent: Agent,
        instructions: String = "",
        memories: [AgentContextMemory] = [],
        resources: [AgentContextResource] = [],
        diagnostics: [TurnDiagnostic] = [],
        primaryThreadSummary: String? = nil,
        revision: String? = nil
    ) {
        self.init(
            identity: AgentContextIdentity(
                agentID: agent.id,
                name: agent.name,
                description: agent.description
            ),
            instructions: instructions,
            memories: memories,
            resources: resources,
            diagnostics: diagnostics,
            primaryThreadSummary: primaryThreadSummary,
            revision: revision
        )
    }

}

/// Authoritative typed continuity source for managed Turns.
public protocol AgentContextSource: Sendable {
    func snapshot(for agent: Agent, thread: Thread) async throws -> AgentContextSnapshot
}

public extension AgentContextSource {
    /// Descriptive alias for hosts that prefer “context” terminology at call sites.
    func context(for agent: Agent, thread: Thread) async throws -> AgentContextSnapshot {
        try await snapshot(for: agent, thread: thread)
    }
}

/// Minimal source used by lower-level engine tests and hosts that do not configure continuity
/// storage. It preserves identity while making the absence of Agent memory explicit.
public struct IdentityAgentContextSource: AgentContextSource {
    public init() {}

    public func snapshot(for agent: Agent, thread _: Thread) async throws -> AgentContextSnapshot {
        AgentContextSnapshot(agent: agent)
    }
}

/// Default filesystem-backed Agent continuity source.
///
/// The source reads root `SOUL.md` as stable instructions and builds a compact catalog from
/// recursive Markdown files under `Notes/`. Full note contents remain on disk and are loaded on
/// demand through generic workspace file tools. If a host uses a non-filesystem primary Workspace,
/// the source still returns the durable identity and leaves filesystem context empty; hosts that
/// need another backing should inject their own ``AgentContextSource``.
public actor DefaultAgentContextSource: AgentContextSource {
    private let workspaceStore: any WorkspaceStore
    private let maxFileCount: Int
    private let maxBytes: Int

    public init(
        workspaceStore: any WorkspaceStore,
        maxFileCount: Int = 100,
        maxBytes: Int = 1_048_576
    ) {
        self.workspaceStore = workspaceStore
        self.maxFileCount = max(0, maxFileCount)
        self.maxBytes = max(0, maxBytes)
    }

    public func snapshot(for agent: Agent, thread: Thread) async throws -> AgentContextSnapshot {
        var instructions = ""
        var resources: [AgentContextResource] = []
        var revision = ""
        var diagnostics: [TurnDiagnostic] = []

        if let workspaceID = agent.primaryWorkspaceID,
           let reference = try await workspaceStore.fetchWorkspace(id: workspaceID, includeTools: false),
           let rootPath = reference.rootPath
        {
            let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
            let soulURL = rootURL.appendingPathComponent("SOUL.md")
            if let content = try? String(contentsOf: soulURL, encoding: .utf8) {
                instructions = utf8Prefix(of: content, byteCount: maxBytes)
            } else {
                diagnostics.append(TurnDiagnostic(
                    dependency: .context,
                    operation: "readSoul",
                    entityID: agent.id.uuidString,
                    errorIdentity: nil,
                    message: "SOUL.md is missing or unreadable; continuing with Agent identity only."
                ))
            }

            let notesURL = URL(fileURLWithPath: rootPath, isDirectory: true)
                .appendingPathComponent("Notes", isDirectory: true)
            do {
                // Catalog metadata is bounded and cheap enough to rebuild for every admitted
                // Turn. This keeps ordinary filesystem writes, including host-side edits, visible
                // on the next Turn without requiring a fragile invalidation callback.
                resources = try discoverCatalog(at: notesURL)
                revision = stableRevision(resources, soul: instructions)
            } catch {
                diagnostics.append(TurnDiagnostic(
                    dependency: .context,
                    operation: "catalogNotes",
                    entityID: agent.id.uuidString,
                    errorIdentity: nil,
                    message: "Notes catalog is unavailable: \(error.localizedDescription)"
                ))
            }
        }

        return AgentContextSnapshot(
            agent: agent,
            instructions: instructions,
            resources: resources,
            diagnostics: diagnostics,
            primaryThreadSummary: nil,
            revision: revision.isEmpty ? nil : revision
        )
    }

    private func noteFiles(at notesURL: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: notesURL.path) else { return [] }
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: notesURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        var files: [URL] = []
        while let fileURL = enumerator.nextObject() as? URL {
            guard fileURL.pathExtension.lowercased() == "md",
                  ((try? fileURL.resourceValues(forKeys: Set(keys)).isRegularFile) ?? false)
            else { continue }
            files.append(fileURL)
        }
        return files.sorted { $0.path < $1.path }
    }

    private func discoverCatalog(at notesURL: URL) throws -> [AgentContextResource] {
        let files = try noteFiles(at: notesURL)
        var resources: [AgentContextResource] = []
        var remainingBytes = maxBytes
        let notesRoot = notesURL.resolvingSymlinksInPath().standardizedFileURL.path
        for fileURL in files.prefix(maxFileCount) {
            guard remainingBytes > 0 else { continue }
            let resolvedFile = fileURL.resolvingSymlinksInPath().standardizedFileURL.path
            guard resolvedFile.hasPrefix(notesRoot + "/") else { continue }
            let safeFileURL = URL(fileURLWithPath: resolvedFile)
            guard let content = try? String(contentsOf: safeFileURL, encoding: .utf8)
            else { continue }
            let bounded = utf8Prefix(of: content, byteCount: min(remainingBytes, 4_096))
            remainingBytes -= bounded.utf8.count
            let path = resolvedFile.replacingOccurrences(of: notesRoot + "/", with: "")
            resources.append(AgentContextResource(path: "Notes/\(path)", description: description(for: bounded, filename: fileURL.lastPathComponent)))
        }
        resources.sort { $0.path < $1.path }
        return resources
    }

    private func description(for content: String, filename: String) -> String {
        let lines = content.components(separatedBy: .newlines)
        if lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "---" {
            for line in lines.dropFirst() {
                if line.trimmingCharacters(in: .whitespacesAndNewlines) == "---" { break }
                let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
                if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == "description" {
                    return parts[1].trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                }
            }
        }
        if let heading = lines.first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }) {
            let value = heading.trimmingCharacters(in: .whitespacesAndNewlines).drop { $0 == "#" || $0 == " " }
            if !value.isEmpty { return String(value) }
        }
        return URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
    }

    private func stableRevision(_ resources: [AgentContextResource], soul: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in (soul + "\0" + resources.map { "\($0.path)\0\($0.description)\n" }.joined()).utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return String(hash, radix: 16)
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
