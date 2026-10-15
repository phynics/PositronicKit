import Foundation
import PKContracts
import PKUtilities

/// Curated tool sets a host can pass through ``TurnOptions/tools``.
///
/// Direct execution takes its tools only from ``TurnOptions/tools``; the runtime never injects a
/// tool set implicitly. A fork, for example, supplies no tools of its own, so the caller chooses
/// the tools a fork Turn may use.
public enum RuntimeToolSets {
    /// The read-only filesystem tools rooted at `root`.
    ///
    /// The set lists and searches files and reads file contents inside `root`. It contains no
    /// tool that creates, modifies, or deletes a file, so a Turn given only this set cannot
    /// change the filesystem.
    ///
    /// - Parameter root: The directory every tool is jailed to.
    /// - Returns: The read-only filesystem tools for `root`.
    public static func readOnlyFilesystem(root: URL) -> [any PKTool] {
        let path = root.path
        return [
            ListDirectoryTool(currentDirectory: path, jailRoot: path),
            FindFileTool(currentDirectory: path, jailRoot: path),
            SearchFileContentTool(currentDirectory: path, jailRoot: path),
            SearchFilesTool(currentDirectory: path, jailRoot: path),
            ReadFileTool(currentDirectory: path, jailRoot: path),
        ]
    }
}
