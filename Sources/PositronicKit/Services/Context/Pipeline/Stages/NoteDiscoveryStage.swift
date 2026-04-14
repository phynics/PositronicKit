import ErrorKit
import Foundation
import Logging
import PKPrompt
import PKShared

/// Pipeline stage responsible for discovering relevant filesystem notes in the workspace.
public struct NoteDiscoveryStage: PipelineStage {
    /// The workspace to search for notes.
    public let workspace: (any WorkspaceProtocol)?
    private let logger = Logger.module(named: "com.positronickit.NoteDiscoveryStage")

    /// Initializes a new note discovery stage.
    /// - Parameter workspace: The workspace to search.
    public init(workspace: (any WorkspaceProtocol)? = nil) {
        self.workspace = workspace
    }

    /// Searches the workspace for Markdown notes and updates the context.
    /// - Parameter context: The shared pipeline context.
    /// - Returns: A stream that yields a discovery progress event.
    public func process(
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

        for filePath in files where filePath.hasSuffix(".md") {
            guard let content = try? await workspace.readFile(path: filePath) else {
                continue
            }
            let name = URL(fileURLWithPath: filePath).deletingPathExtension().lastPathComponent

            let note = ContextFile(
                name: name,
                content: content,
                source: filePath
            )
            allNotes.append(note)
        }

        return allNotes.sorted(by: { $0.name < $1.name })
    }
}
