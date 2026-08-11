import Foundation
import Logging
import PKPrompt
import PKShared
import PKUtilities

/// Pipeline stage responsible for discovering relevant filesystem notes in the workspace.
struct NoteDiscoveryStage: PipelineStage {
    private enum Defaults {
        static let maxFileCount = 100
        static let maxTotalBytes = 1_048_576
    }

    /// The workspace to search for notes.
    let workspace: (any Workspace)?
    /// The maximum number of Markdown files to read.
    let maxFileCount: Int
    /// The maximum number of UTF-8 bytes to retain across discovered notes.
    let maxTotalBytes: Int
    private let logger = Logger.module(named: "note-discovery")

    /// Initializes a new note discovery stage.
    /// - Parameters:
    ///   - workspace: The workspace to search.
    ///   - maxFileCount: The maximum number of Markdown files to read.
    ///   - maxTotalBytes: The maximum number of UTF-8 bytes to retain across notes.
    init(
        workspace: (any Workspace)? = nil,
        maxFileCount: Int = Defaults.maxFileCount,
        maxTotalBytes: Int = Defaults.maxTotalBytes
    ) {
        self.workspace = workspace
        self.maxFileCount = max(0, maxFileCount)
        self.maxTotalBytes = max(0, maxTotalBytes)
    }

    /// Searches the workspace for Markdown notes and updates the context.
    /// - Parameter context: The shared pipeline context.
    /// - Returns: A stream that yields a discovery progress event.
    func process(
        _ context: ContextPipelineContext
    ) async throws -> AsyncThrowingStream<ContextGatheringEvent, Error> {
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    continuation.yield(.progress(.discoveringNotes))
                    let notes = try await fetchAllNotes()
                    await context.setResults(notes: notes)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    /// Fetches all Markdown notes from the workspace "Notes" directory.
    /// - Returns: An array of `ContextFile` objects sorted by name.
    /// - Throws: An error if the workspace listing or reading fails.
    private func fetchAllNotes() async throws -> [ContextFile] {
        var allNotes: [ContextFile] = []

        guard let workspace = workspace else {
            return []
        }

        let files = try await workspace.listFiles(path: "Notes")
            .filter { $0.hasSuffix(".md") }
            .sorted()
            .prefix(maxFileCount)

        var remainingBytes = maxTotalBytes

        for filePath in files {
            guard remainingBytes > 0 else { break }

            guard let content = try? await workspace.readFile(path: filePath) else {
                continue
            }

            let loadedContent: String
            let contentByteCount = content.utf8.count
            if contentByteCount <= remainingBytes {
                loadedContent = content
                remainingBytes -= contentByteCount
            } else {
                loadedContent = utf8Prefix(of: content, byteCount: remainingBytes)
                remainingBytes = 0
            }

            let name = URL(fileURLWithPath: filePath).deletingPathExtension().lastPathComponent

            let note = ContextFile(
                name: name,
                content: loadedContent,
                source: filePath
            )
            allNotes.append(note)
        }

        return allNotes.sorted {
            if $0.name == $1.name {
                return $0.source < $1.source
            }
            return $0.name < $1.name
        }
    }

    /// Returns a whole-character prefix that fits within the UTF-8 byte budget.
    private func utf8Prefix(of content: String, byteCount: Int) -> String {
        guard byteCount > 0 else { return "" }

        var prefix = ""
        prefix.reserveCapacity(min(content.utf8.count, byteCount))
        var usedBytes = 0

        for character in content {
            let characterByteCount = character.utf8.count
            guard usedBytes + characterByteCount <= byteCount else { break }
            prefix.append(character)
            usedBytes += characterByteCount
        }

        return prefix
    }
}
