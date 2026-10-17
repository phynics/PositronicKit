import Foundation
import PKContracts

/// Generic seed content for a newly created Agent private workspace.
///
/// The runtime writes only what a host supplies here. The opinionated identity-file and
/// `Notes/` templates live in the optional `PKAgentFiles` adapter; the runtime default
/// (``none``) writes neither. Files supplied through the template's
/// `AgentTemplate.workspaceFilesSeed` are
/// still written by ``WorkspaceCatalog/createAgentWorkspace(agentID:template:)`` independently of
/// this value.
public struct AgentWorkspaceSeed: Sendable {
    /// The workspace-root-relative file written with the produced identity content, or `nil` to
    /// write none. Existing files are never overwritten.
    public let identityFilename: String?

    /// Produces the identity-file content for the creation template.
    public let identityContent: @Sendable (AgentTemplate?) -> String

    /// Extra files written under the workspace `Notes/` directory, keyed by Notes-relative path.
    /// Existing files and files already supplied by the template are never overwritten.
    public let notes: [String: String]

    public init(
        identityFilename: String?,
        identityContent: @escaping @Sendable (AgentTemplate?) -> String,
        notes: [String: String] = [:]
    ) {
        self.identityFilename = identityFilename
        self.identityContent = identityContent
        self.notes = notes
    }

    /// Writes no seed content. This is the runtime default.
    public static let none = AgentWorkspaceSeed(identityFilename: nil, identityContent: { _ in "" })
}
