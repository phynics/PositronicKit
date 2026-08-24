---
status: accepted
---

# Workspace binding and execution authority

The v4 design requires ordinary Workspaces to be exclusively bound through durable conditional
Thread bindings, with a process-local coordinator serializing execution per Workspace while
allowing different Workspaces to run concurrently. We reject mutable Workspace-ID arrays as
authority and do not require a distributed lock in v4: binding ownership must be durable, while
hosts with multi-process shared Workspaces provide stronger coordination in their backend.

## Migration boundary

`Thread` does not contain, encode, or decode the legacy `attachedWorkspaceIds` projection. A
legacy Thread payload can therefore still be decoded for its remaining metadata, but the unknown
workspace field is intentionally ignored and never recreates a binding. This keeps
`WorkspaceBindingRepository` as the only runtime authority.

Hosts upgrading data written by the 4.0.0-era model must migrate it in their persistence adapter:
read the legacy IDs, validate the workspace records, claim the canonical repository bindings, and
then retire the legacy field. Adapters may instead discard incompatible rows. The runtime does not
perform this migration on lookup or hydration, so a custom `ThreadPersistenceProtocol` cannot
silently reintroduce a second authority.
