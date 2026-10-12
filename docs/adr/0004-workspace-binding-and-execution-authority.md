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

## Amendment

[ADR 0016](0016-admission-authority-provider.md) generalizes binding ownership from a Timeline to a
principal and replaces the dispatcher's primary-Workspace boolean with an explicit binding kind.
Durable exclusive ownership, the conditional-claim boundary, and process-local serialization per
Workspace are unchanged. 7.0 keeps the current shape; 8.0 implements the generalization.

## Amendment: abandoned mutating tools keep the lane closed

The no-overlap guarantee also covers work the runtime stops waiting for. When a `.mutating` or
`.externalProcess` tool times out, `ToolTimeoutEnforcer` reports
`ToolError.timedOutButMayStillBeRunning` and abandons the still-running task. The Workspace
Execution Lane keeps that Workspace's lane closed after the timed-out operation returns, until the
abandoned task actually ends. A later call for the same Workspace therefore waits instead of
overlapping the tool; calls for other Workspaces are unaffected. The lane observes the abandoned
task with one unstructured watcher per hold, so the timed-out operation's own structured scope is
unchanged and the hold cannot be cancelled by that operation's cancellation.

A pending human approval still holds the lane for as long as the approval decision takes. Moving
approval resolution outside the lane is a separate behavior change tracked by #257.
