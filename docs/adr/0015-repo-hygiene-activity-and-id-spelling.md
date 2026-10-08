---
status: accepted
---

# Repo hygiene follow-up: activity projection removal and ID spelling

Follow-up to issue #257 recording the surviving decisions from the planning
documents removed in issue #271.

## Primary-Timeline activity projection

Issue #72 introduced a bounded internal experiment mirroring primary-Workspace
tool activity into an Agent's private Timeline. PR #86 merged it and PR #87
removed the sink before the 4.0 public API freeze. Tool activity is durable
only on the Timeline whose Turn executed it; Agent private-Timeline history
changes through explicit Agent lifecycle and Turn operations. A future
projection feature requires its own issue, consumer story, bounded retention
semantics, and an accepted history contract.

## Public ID parameter spelling

Public APIs use `ID`/`IDs` consistently (`originID`, `agentID`, `timelineID`,
`workspaceID`, `turnID`, `requestID`, `toolCallID`, `modelRoundIndex`,
`toolName`). Serialized keys retain their established wire spellings
(`threadId`, `agentId`, `turnId`, `requestId`, `toolCallId`). No decoder
accepts a retired key and no public compatibility shim forwards from a retired
parameter spelling.
