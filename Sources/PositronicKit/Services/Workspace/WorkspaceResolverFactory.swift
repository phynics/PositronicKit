import Foundation
import PKShared

/// Composes the bundled default `WorkspaceResolver` stack (local `DefaultWorkspaceCatalog` +
/// an injected `WorkspaceFactory`) so that neither `ThreadManager` nor the top-level
/// `PositronicKit` facade needs to know how the default catalog/factory/resolver pieces fit
/// together. Hosts that want a fully custom `WorkspaceResolver` (no default catalog/factory
/// involved at all) should construct and inject their own conformer instead of going through
/// this factory.
public enum WorkspaceResolverFactory {
    /// Builds the default `WorkspaceResolver`: a `DefaultWorkspaceResolver` backed by a
    /// `DefaultWorkspaceCatalog` rooted at `workspaceRoot` and persisted via `workspaceStore`,
    /// with workspace instantiation delegated to `workspaceCreator`.
    public static func makeDefault(
        workspaceRoot: URL,
        workspaceStore: any WorkspaceStore,
        workspaceCreator: any WorkspaceFactory = NullWorkspaceCreator()
    ) -> any WorkspaceResolver {
        DefaultWorkspaceResolver(
            repository: DefaultWorkspaceCatalog(
                workspaceRoot: workspaceRoot,
                workspacePersistence: workspaceStore
            ),
            workspaceCreator: workspaceCreator
        )
    }
}
