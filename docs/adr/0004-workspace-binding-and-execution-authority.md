---
status: accepted
---

# Workspace binding and execution authority

The v4 design requires ordinary Workspaces to be exclusively bound through durable conditional
Thread bindings, with a process-local coordinator serializing execution per Workspace while
allowing different Workspaces to run concurrently. We reject mutable Workspace-ID arrays as
authority and do not require a distributed lock in v4: binding ownership must be durable, while
hosts with multi-process shared Workspaces provide stronger coordination in their backend.
