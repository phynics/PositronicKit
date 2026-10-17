import Foundation
import PKContracts
import PositronicKit

/// Filesystem-backed Agent continuity source for the `PKAgentFiles` conventions.
///
/// The source reads the root `SOUL.md` as stable instructions and builds a compact catalog from
/// recursive Markdown files under `Notes/`. Full note contents remain on disk and are loaded on
/// demand through generic workspace file tools. If a host uses a non-filesystem primary Workspace,
/// the source still returns the durable identity and leaves filesystem context empty.
public actor FileSystemAgentContextSource: AgentContextSource {
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

    public func snapshot(for agent: Agent, timeline: TimelineRecord) async throws -> AgentContextSnapshot {
        var instructions = ""
        var resources: [AgentContextResource] = []
        var diagnostics: [TurnDiagnostic] = []

        if let workspaceID = agent.primaryWorkspaceID,
           let reference = try await workspaceStore.fetchWorkspace(id: workspaceID, includeTools: false),
           let rootPath = reference.rootPath
        {
            let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
            let soulURL = rootURL.appendingPathComponent("SOUL.md")
            if let content = try? String(contentsOf: soulURL, encoding: .utf8) {
                instructions = content.utf8Prefix(maxBytes: maxBytes)
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
            primaryTimelineSummary: nil
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
            let bounded = content.utf8Prefix(maxBytes: min(remainingBytes, 4_096))
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
}

private extension String {
    /// The longest prefix of whole characters whose UTF-8 encoding fits in `byteCount` bytes.
    /// A character is never split, so the result is always valid text.
    func utf8Prefix(maxBytes byteCount: Int) -> String {
        guard byteCount > 0 else { return "" }
        var output = ""
        var used = 0
        for character in self {
            guard used + character.utf8.count <= byteCount else { break }
            output.append(character)
            used += character.utf8.count
        }
        return output
    }
}
