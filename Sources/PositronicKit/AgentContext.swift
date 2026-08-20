import Foundation
import PKContracts

/// Errors raised when an authoritative Agent context cannot be used for the admitted identity.
public enum AgentContextError: Error, Equatable, Sendable, LocalizedError {
    case identityMismatch(expected: UUID, actual: UUID)

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

/// The immutable Agent continuity captured for one managed Turn.
///
/// The runtime owns the reserved prompt section mapping. Sources return typed data rather
/// than arbitrary prompt nodes, so a host can replace filesystem storage with a database,
/// remote service, or a no-memory implementation without changing Turn orchestration.
public struct AgentContextSnapshot: Codable, Equatable, Sendable {
    public let identity: AgentContextIdentity
    public let instructions: String
    public let memories: [AgentContextMemory]
    public let primaryThreadSummary: String?
    public let revision: String?

    public init(
        identity: AgentContextIdentity,
        instructions: String = "",
        memories: [AgentContextMemory] = [],
        primaryThreadSummary: String? = nil,
        revision: String? = nil
    ) {
        self.identity = identity
        self.instructions = instructions
        self.memories = memories
        self.primaryThreadSummary = primaryThreadSummary
        self.revision = revision
    }

    public init(
        agent: Agent,
        instructions: String = "",
        memories: [AgentContextMemory] = [],
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
/// The source reads `Notes/system.md` as stable instructions and other Markdown files under
/// the Agent's primary Workspace as bounded continuity items. If a host uses a non-filesystem
/// primary Workspace, the source still returns the durable identity and leaves continuity empty;
/// hosts that need another backing should inject their own ``AgentContextSource``.
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

    public func snapshot(for agent: Agent, thread _: Thread) async throws -> AgentContextSnapshot {
        var instructions = ""
        var memories: [AgentContextMemory] = []

        if let workspaceID = agent.primaryWorkspaceID,
           let reference = try await workspaceStore.fetchWorkspace(id: workspaceID, includeTools: false),
           let rootPath = reference.rootPath
        {
            let notesURL = URL(fileURLWithPath: rootPath, isDirectory: true)
                .appendingPathComponent("Notes", isDirectory: true)
            let files = try noteFiles(at: notesURL)
            var remainingBytes = maxBytes
            for fileURL in files.prefix(maxFileCount) {
                guard remainingBytes > 0,
                      let content = try? String(contentsOf: fileURL, encoding: .utf8)
                else { continue }

                let bounded = utf8Prefix(of: content, byteCount: remainingBytes)
                remainingBytes -= bounded.utf8.count
                let source = fileURL.pathComponents.suffix(2).joined(separator: "/")
                if fileURL.lastPathComponent.lowercased() == "system.md" {
                    instructions = bounded
                } else {
                    memories.append(AgentContextMemory(content: bounded, source: source))
                }
            }
        }

        return AgentContextSnapshot(
            agent: agent,
            instructions: instructions,
            memories: memories,
            primaryThreadSummary: nil,
            revision: agent.updatedAt.iso8601String
        )
    }

    private func noteFiles(at notesURL: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: notesURL.path) else { return [] }
        let keys: [URLResourceKey] = [.isRegularFileKey]
        return try FileManager.default.contentsOfDirectory(
            at: notesURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        )
        .filter { url in
            url.pathExtension.lowercased() == "md"
                && ((try? url.resourceValues(forKeys: Set(keys)).isRegularFile) ?? false)
        }
        .sorted { $0.path < $1.path }
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

private extension Date {
    var iso8601String: String {
        ISO8601DateFormatter().string(from: self)
    }
}
