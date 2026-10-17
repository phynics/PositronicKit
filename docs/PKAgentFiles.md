# Agent files

`PKAgentFiles` is the optional runtime adapter that installs the opinionated filesystem **Agent**
conventions. `PositronicKit` itself is neutral: managed Turns capture identity only, no Agent
write is approval-gated, and no identity file or note template is seeded. Install this adapter to
restore the filesystem behavior.

`PKAgentFiles` imports `PositronicKit`, is never imported by the runtime or a provider, and uses
only public API.

## What it installs

| Convention | Value | Effect |
| --- | --- | --- |
| Agent context | `FileSystemAgentContextSource` | Reads the primary Workspace's root `SOUL.md` as instructions and catalogs Markdown under `Notes/` |
| Workspace seed | `PKAgentFiles.seedNotes` | Writes the `SOUL.md` identity template and `Notes/MEMORY.md` into a new Agent workspace |
| Write approval | `PKAgentFiles.protectedPaths` (`["SOUL.md"]`) | Requires approval for mutating primary-Workspace file tools that target the identity file |

The seed is generic: `AgentWorkspaceSeed` carries an identity filename and content producer plus
Notes-relative files. A host can supply its own seed instead of the bundled one.

## Install

Add the product to the target that composes the runtime:

```swift skip
.target(
    name: "MyApp",
    dependencies: [
        .product(name: "PositronicKit", package: "PositronicKit"),
        .product(name: "PKAgentFiles", package: "PositronicKit"),
    ]
)
```

## Compose the runtime

`PKAgentFiles` supplies all three conventions in one call. Build the runtime configuration from
the persistence configuration so the context source reads the same Workspace store the runtime
writes.

```swift
import PKAgentFiles
import PositronicKit

let persistence = PKRuntime.PersistenceConfiguration(runtimeRepository: InMemoryTimelineRuntimeRepository())
let runtime = PKRuntime.RuntimeConfiguration.agentFiles(
    persistence: persistence,
    workspaceProfile: .noWorkspace
)
let kit = PKRuntime(configuration: .init(
    languageModel: myLanguageModel,
    persistence: persistence,
    runtime: runtime
))
```

To compose the pieces yourself, use `RuntimeCustomization.agentFiles(workspaceStore:)` for the
context source and seed, and `RuntimeToolPolicy(protectedPrimaryWorkspacePaths: PKAgentFiles.protectedPaths)`
for the write gate.

## Gate every write

`protectedPrimaryWorkspacePaths` accepts glob-like workspace-relative patterns. `*` matches within
one path segment and `**` matches across segments; matching is case-insensitive and also applies to
the symlink-resolved target of a local provider. Pass `["**"]` to require approval for every
mutating primary-Workspace file tool.

```swift
let policy = RuntimeToolPolicy(protectedPrimaryWorkspacePaths: ["**"])
```

## Neutral default

Without `PKAgentFiles`, `IdentityAgentContextSource` returns the Agent's stored name, description,
and instructions only. `DefaultWorkspaceCatalog` writes only the template's
`workspaceFilesSeed`, and `AgentWorkspaceFileTool.requiresPermission(for:)` returns `false` for
every path because the protected-path list is empty.
