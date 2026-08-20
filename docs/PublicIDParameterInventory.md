# Public ID Parameter Inventory

This inventory records the canonical v4 spelling for public identifier parameters. Public APIs
use `ID`/`IDs` consistently; the hard cut does not retain source aliases or legacy forwarding
overloads.

| Surface | Canonical spelling |
| --- | --- |
| Workspace catalog creation | `originID`, `agentID`, `threadID` |
| Agent manager attachment | `agentID`, `threadID` |
| Thread and workspace lookup | `threadID`, `agentID`, `workspaceID` |
| Turn request and identity | `turnID`, `requestID`, `modelRoundIndex` |
| Tool calls and progress events | `toolCallID` |
| Workspace URI factories | `agentID`, `threadID` |

Serialized keys follow the same v4 vocabulary (`threadId`, `agentId`, `turnId`, `requestId`, and
`toolCallId`). No decoder accepts a retired key, and no public compatibility shim forwards from a
retired parameter spelling.
