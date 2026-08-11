# Public ID Parameter Inventory

This inventory completes PKAPI-004. Canonical Swift APIs use `ID`/`IDs`; historical wire keys stay
unchanged. Deprecated source shims remain through the next major release.

| Category | Legacy API | Canonical API | Compatibility policy |
| --- | --- | --- | --- |
| Protocol requirement | `WorkspaceCatalog.createWorkspace(...originId:...)` | `createWorkspace(...originID:...)` | Legacy spelling remains the sole requirement; the canonical protocol-extension method forwards once to it. |
| Protocol requirement | `WorkspaceCatalog.createAgentWorkspace(instanceId:...)` | `createAgentWorkspace(instanceID:...)` | Legacy spelling remains the sole requirement; the canonical protocol-extension method forwards once to it. |
| Protocol requirement | `AgentInstanceManagerProtocol.attach(agentId:to:)` | `attach(agentID:to:)` | Legacy spelling remains the sole requirement; canonical convenience forwards once. |
| Protocol requirement | `AgentInstanceManagerProtocol.detach(agentId:from:)` | `detach(agentID:from:)` | Legacy spelling remains the sole requirement; canonical convenience forwards once. |
| Protocol requirement | `getTimelines(attachedTo agentId:)` | `timelines(attachedTo agentID:)` | Existing legacy requirement and one-way canonical query retained. |
| Concrete method | `DefaultWorkspaceCatalog` legacy creation overloads | `originID` / `instanceID` overloads | Canonical implementation plus deprecated one-way legacy forwards. |
| Concrete method | `AgentInstanceManager` legacy attach/detach overloads | `agentID` / `timelineID` overloads | Canonical implementation plus deprecated one-way legacy forwards. |
| Enum constructor | ChatEvent nested `toolCallId` constructors | `toolCallID` constructors | Deprecated legacy static constructors forward to canonical cases. |
| Factory helper | `toolProgress`, `toolCallError`, `toolCompleted` with `toolCallId` | Helpers with `toolCallID` | Deprecated legacy helpers forward once. |
| Unlabeled factory | `WorkspaceURI.agentWorkspace(_:)`, `timelineWorkspace(_:)` internal parameter names | `agentID`, `timelineID` | Source-neutral because the argument is unlabeled. |

## Wire compatibility

ChatEvent's canonical associated-value label is `toolCallID`, but explicit Codable keys preserve
the serialized `"toolCallId"` field. Existing Codable model shims likewise retain their documented
legacy keys.

## Conformer compatibility

Protocol migrations intentionally do not use reciprocal defaults. Tests define third-party-style
conformers implementing only the legacy requirements and verify canonical calls dispatch exactly
once. Removing the legacy requirements is deferred until the next major release.
