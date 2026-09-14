# Persistence layer

PositronicKit defines focused persistence protocols and one cohesive repository for Turn execution.

## Domain-specific protocols

- `ThreadMessageStoreProtocol` persists append-only Thread messages and prompt snapshots.
- `ThreadPersistenceProtocol` persists Thread metadata and lifecycle state.
- `WorkspaceStore` persists Workspace references.
- `WorkspaceBindingRepository` persists exclusive claims between ordinary Workspaces and Threads.
  An Agent primary Workspace remains Agent-owned.
- `RequestOriginStoreProtocol` persists request-origin identity and hosted-tool metadata.
- `ToolPersistenceProtocol` persists tool registry and routing metadata.
- `ThreadRuntimeRepository` owns Thread history and Turn lifecycle transitions as one atomic
  boundary. It refines the Thread and message store protocols.

## Thread runtime repository

Every Turn execution path receives one `ThreadRuntimeRepository`. The repository is the transaction
boundary for Request-ID uniqueness, active-Turn serialization, append-only `ThreadMessage` history,
tool intents and results, terminal outcomes, notices, and stale-Turn recovery.

The runtime begins provider requests and tool execution only after the corresponding repository
operation succeeds. Admission accepts the Turn and its optional input message together. Terminal
completion can append the final assistant message in the same transaction.

`deleteThread(id:)` must delete the Thread's durable messages and summary projections with the Thread.
History remains append-only while the Thread exists. `deleteMessages(for:)` remains forbidden for
ordinary history pruning.

## Workspace execution

The runtime uses a process-local FIFO lane for each ordinary Workspace. Calls for one Workspace do
not overlap, while calls for different Workspaces can run concurrently. A multi-process host must
provide stronger coordination in its persistence backend when it needs it.

Attached Workspace execution is a message-only external continuation. The source Turn records its
Tool Intent and ends with an external-deferral outcome before the host performs the side effect. A
later submission persists the host's Tool message through the Thread message boundary. It does not
record a `RuntimeToolResult` for the interrupted source Turn.

## Composition

`PositronicKit.PersistenceConfiguration` resolves the Workspace binding repository once and passes
that value to the runtime graph. Use `inMemory()` for tests and prototypes. Use
`fullyPersistent(...)` when every store must survive a process restart.

PositronicKit does not ship a database backend. Hosts provide storage that conforms to the focused
protocols. A store reports whether it survives restart through `DurabilityAware`, and
`PersistenceConfiguration.validateDurability()` identifies mixed durable and in-memory setups.
