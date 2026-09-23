# Public ID Parameter Inventory

This inventory records the canonical v4 spelling for public identifier parameters. Public APIs
use `ID`/`IDs` consistently; the hard cut does not retain source aliases or legacy forwarding
overloads.

| Surface | Canonical spelling |
| --- | --- |
| Workspace catalog creation | `originID`, `agentID`, `timelineID` |
| Agent manager attachment | `agentID`, `timelineID` |
| Timeline and workspace lookup | `timelineID`, `agentID`, `workspaceID` |
| Turn request and identity | `turnID`, `requestID`, `modelRoundIndex` |
| Tool calls and progress events | `toolCallID` |
| Workspace URI factories | `agentID`, `timelineID` |
| Tool routing | `workspaceID`, `toolName` |
| Agent-attached Timeline lookup | `agentID` |
| Timeline tool toggling | `toolName` |


Serialized keys retain their established wire spellings (`threadId`, `agentId`, `turnId`, `requestId`, and
`toolCallId`). No decoder accepts a retired key, and no public compatibility shim forwards from a
retired parameter spelling.
