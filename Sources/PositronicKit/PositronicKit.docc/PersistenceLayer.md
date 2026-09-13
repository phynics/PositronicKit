# Persistence Layer

Modular storage architecture for PKRuntime.

## Domain-Specific Protocols

The persistence layer is split into focused protocols to ensure high cohesion and low coupling:

- `MessageStoreProtocol`: Chat history management.
- `TimelinePersistenceProtocol`: Timeline lifecycle.
- `WorkspaceStore`: Virtual document workspace tracking.
- `WorkspaceBindingRepository`: Atomic exclusive claims between ordinary Workspaces and Timelines;
  Agent primary Workspace ownership remains on the Agent record.
- `RequestOriginStoreProtocol`: Request-origin identity and attached-tool metadata.
- `ToolPersistenceProtocol`: PKTool registry and routing metadata.
- `TimelineRuntimeRepository`: Atomic Timeline history and Turn lifecycle transitions.

## Implementation

For v4 Turn execution, hosts that need durable admission and recovery inject one
`TimelineRuntimeRepository`. It is the transaction boundary for Request-ID uniqueness, active-Turn
serialization, append-only `TimelineMessage` history, tool intents/results, terminal outcomes, and
stale-Turn recovery. The repository's successful admission and intent/result operations are the
durable-before-side-effect barriers: provider requests and tool execution begin only after the
corresponding record is accepted.

Workspace execution uses a process-local FIFO lane per ordinary Workspace. This prevents
overlapping tool side effects for one Workspace while allowing different Workspaces to proceed
concurrently; multi-process hosts provide stronger coordination in their backend.

`TimelineRuntimeRepository` does not own `PromptJournal` state and does not derive semantic summaries from
prompt history. A `TimelineSummary` is a separate projection that may reference only message IDs already
accepted into append-only history.

Attached Workspace execution is intentionally a message-only external continuation. The source Turn
records its PKTool Intent, emits the external-deferral terminal outcome, and becomes interrupted before
the host performs the side effect. A later submission persists the host's PKTool message through the
Timeline message boundary, but does not record a `RuntimeToolResult`: the submission contract has no
originating Turn ID, and the interrupted source Turn cannot accept a result without reopening its
terminal lifecycle. `fetchToolResults` therefore describes runtime-executed calls only; this contract
avoids inventing a second lifecycle or weakening the atomic local result boundary.

PKRuntime does not ship a canonical database backend. Hosts provide the storage implementation that fits their environment, whether that is in-memory state, SQLite, cloud storage, or another persistence layer that conforms to the store protocols.

### Composition

Live runtime code depends on focused store protocols directly. `PKRuntime.PersistenceConfiguration` groups the commonly required stores for initialization, but runtime services should continue to depend on narrow protocols rather than a monolithic persistence facade.
