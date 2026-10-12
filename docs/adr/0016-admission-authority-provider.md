---
status: accepted
---

# Admission authority provider and opaque principal

Issue [#291](https://github.com/phynics/PositronicKit/issues/291) records the design-only decision
for 7.0 that would later let Agents sit above a substrate core ([#286](https://github.com/phynics/PositronicKit/issues/286)
Alternative B, [#292](https://github.com/phynics/PositronicKit/issues/292)). 7.0 ships no
implementation. The decision and the guardrails below exist so the frozen 7.0 admission, attachment,
and durable record shapes do not encode Agent-only assumptions that would force a second breaking
migration in 8.0.

## Context

Admission, durable attribution, and Workspace dispatch are currently Agent-shaped:

- `TurnPreparation.admitTurn` branches on `TurnExecutionKind.agentManaged` / `.direct`, fetches an
  `Agent`, checks `TimelineRecord.attachedAgentID`, calls `AgentContextSource`, and passes the
  resolved `agent.primaryWorkspaceID` into `captureWorkspaceToolCatalog`.
- `TimelineRuntimeRepository.admitTurn(...)` persists `executionKind` and `capturedAgentID`.
  `TurnRecord.capturedAgentID` records the attached Agent for a managed Turn,
  `TimelineMessage.agentID` attributes an authored message, and `TimelineRecord.attachedAgentID`
  holds the single Timeline attachment.
- `WorkspaceToolCatalog.Entry.isPrimary` and `WorkspaceToolDispatcher.execute` special-case the
  Agent primary Workspace. `execute` skips `requireWorkspaceBinding` for that entry, and the
  catalog exposes its file tools directly instead of through `call_tool`.
- `AgentAuthorityCoordinator` is a process-local FIFO lane keyed by Agent identity. `AgentManager`
  uses it for attach, detach, update, retire, and purge, and `TurnPreparation` nests managed
  admission inside it. `AgentManager.retireAgent` drains attached Timelines and the private
  Timeline before it archives the primary Timeline.

Alternative B in [#286](https://github.com/phynics/PositronicKit/issues/286) needs generic
equivalents for those four couplings. This ADR decides the equivalents now. It amends ADR 0005 for admission and
[ADR 0004](0004-workspace-binding-and-execution-authority.md) for Workspace authority. It preserves
the immutability rule in [ADR 0010](0010-runtime-owns-turn-liveness-and-terminal-finalization.md):
authority is captured at admission and does not change while the Turn runs.

## Decision

### 1. One admission path behind an `AdmissionAuthorityProvider`

Admission stops branching on Agent versus direct. The runtime asks one provider for the Turn's
authority once, inside the admission lane, captures the answer immutably, and records only the
durable principal identity in the repository.

```swift skip
public struct TurnPrincipal: Codable, Hashable, Sendable {
    public let id: UUID
    public let kind: PrincipalKind
}

/// An open string tag, not a closed enumeration. The substrate does not enumerate principal kinds.
public struct PrincipalKind: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String
    public static let agent: PrincipalKind = "agent"
    public static let timeline: PrincipalKind = "timeline"
    public static let host: PrincipalKind = "host"
    public static let service: PrincipalKind = "service"
}

public struct AdmissionAuthorityRequest: Sendable {
    public let timelineID: UUID
    public let turnID: UUID
    public let requestID: UUID
    public let message: MessageContent
    public let requestedContributors: [TurnContributor]
}

public struct AdmissionAuthority: Sendable {
    public let principal: TurnPrincipal?
    public let context: TurnContextSnapshot
    public let tools: [AnyTool]
    public let workspaceAuthority: [WorkspaceGrant]
    public let contributors: [TurnContributor]
}

public protocol AdmissionAuthorityProvider: Sendable {
    func authority(for request: AdmissionAuthorityRequest) async throws -> AdmissionAuthority
}
```

The four components map to the couplings above:

| Component | Replaces |
| --- | --- |
| `principal` | `executionKind` plus `capturedAgentID` |
| `context` | `AgentContextSnapshot` for managed Turns |
| `workspaceAuthority` | the `isPrimary` entry path in `captureWorkspaceToolCatalog` |
| `contributors` | the direct-only `DirectTurnContext.contributors` |
| `tools` | the request-scoped tools merged before prompt assembly |

Both public entries converge after the facade. `TimelineHandle.startTurn` uses the runtime's
attached-principal provider, which today resolves the attached Agent and reproduces managed
behavior. `TimelineHandle.startDirectTurn` builds an explicit provider from `DirectTurnContext`, so
the same preparation, admission, and capture path runs. `TurnExecutionKind` stops selecting an
execution path. If the runtime keeps that label for observability, it derives the label from the
provider result and does not add a third case.

The provider result is captured, not consulted again. A provider that samples live Agent state
samples it once, inside the lane, and the Turn runs on that immutable snapshot. A retirement or
Workspace change after admission affects the next Turn, never the admitted one.

Contribution failures keep their present policy: `TurnContextContributionRequirement.required`
fails preparation, and `.optional` records a notice. Provider failure fails closed, consistent with
managed preparation today.

### 2. Opaque `TurnPrincipal` over a durable scalar pair

Durable records carry two scalar fields, `principalId` (UUID) and `principalKind` (open string).
The Swift surface wraps them in `TurnPrincipal`, so call sites read as one identity while storage
and schema stay flat and indexable. The substrate treats `id` as opaque and `kind` as an open tag.

The mapping from today's Agent fields:

| Current symbol | Principal form |
| --- | --- |
| `TimelineRecord.attachedAgentID` | `attachedPrincipal: TurnPrincipal?` |
| `TimelineMessage.agentID` | `principal: TurnPrincipal?` |
| `TurnRecord.capturedAgentID` | `principal: TurnPrincipal?` |
| `AgentContextSnapshot` | `TurnContextSnapshot` |
| `AgentContextSource` | `AdmissionAuthorityProvider` |

`nil` keeps its current meaning: no attachment, no authored attribution, or a direct Turn without a
principal. A direct Turn may carry a `host` principal when the host supplies one.

The Agent-kind context payload keeps its fields. `TurnContextSnapshot` is the principal-neutral
spelling of `AgentContextSnapshot` with the same identity, instructions, memories, resources, and
diagnostics fields. The reserved prompt sections stay runtime-owned, so a source still returns
typed data rather than arbitrary prompt nodes.

#### Decode compatibility

The rename is a one-way rename with a bounded legacy read at the decoder, not a second authority:

- A decoder that sees a legacy key (`attachedAgentId`, `agentId`, or `capturedAgentID`) maps it to
  `TurnPrincipal(id: value, kind: .agent)`.
- If a record carries both a legacy key and its principal replacement, decoding fails closed. It
  never picks a silent winner.
- Encoders write only the principal form. A host store rewrites the legacy shape on its next save.
- Runtime behavior never branches on the legacy key. The compatibility read is removed in the
  release after the one that introduces the principal fields.

This differs from the rejected `attachedWorkspaceIds` projection in ADR 0004. That projection was a
competing authority; this is the same fact under a new name.

#### Host-repository migration

Adapters own the migration; the runtime does not migrate on lookup (ADR 0004).

| Store | Migration |
| --- | --- |
| `PKSQLiteStorage` ([#265](https://github.com/phynics/PositronicKit/issues/265)) | v1 ships principal-ready columns, so 8.0 is not a SQL migration. The 7.0 store extracts `principal_id` / `principal_kind = 'agent'` from the current Agent fields; 8.0 only changes the `body` mapping. |
| Gnostic file repository (JSON via `Codable`) | Decode the legacy keys to `kind = "agent"`, then rewrite the record on its next save. No schema version is needed for JSON. |
| Yakamoz SwiftData | A lightweight migration adds `principalKind` with default `"agent"` and maps or renames the Agent-ID attributes (for example with `@Attribute(originalName:)`) before the first save. |

### 3. Principal-owned Workspaces

A Workspace binding generalizes from a Timeline-owned relationship to a principal-owned binding
with an explicit kind. The Timeline is itself a principal (`kind == "timeline"`), so ordinary
bindings keep their exclusive meaning while the Agent primary Workspace becomes an ordinary
binding of a different kind.

```swift skip
public enum WorkspaceBindingKind: String, Codable, Sendable {
    case ordinary   // bound to a Timeline principal; reached through call_tool
    case primary    // owned by a principal; its file tools are exposed directly
}

public struct WorkspaceBinding: Codable, Equatable, Hashable, Sendable {
    public let workspaceID: UUID
    public let owner: TurnPrincipal
    public let kind: WorkspaceBindingKind
    public let createdAt: Date
    public var updatedAt: Date
}

public struct WorkspaceGrant: Sendable {
    public let workspace: WorkspaceReference
    public let binding: WorkspaceBinding
    public let tools: [AnyTool]
}
```

`WorkspaceToolCatalog.Entry.isPrimary` becomes the grant's `binding.kind`. The dispatcher reads the
kind instead of a boolean:

- `primary` grants expose their file tools directly, as `directTools` does today.
- Every dispatched call revalidates its captured grant against the binding repository immediately
  before the side effect. The `if !route.isPrimary` bypass is deleted; `requireWorkspaceGrant`
  checks owner and kind, so a released or transferred binding fails closed for every kind.

This amends ADR 0004 without discarding it. Durable exclusive ownership and process-local FIFO
serialization per Workspace remain. The owner generalizes from a Timeline to a principal, and the
kind becomes the single dispatch discriminator.

### 4. Drain and retire behind the provider

The admission lane and the lifecycle semantics split by owner:

- The runtime owns a principal admission gate, generalizing `AgentAuthorityCoordinator`. It
  serializes admission and lifecycle transitions per principal, so a retirement cannot commit
  between capturing authority and admitting the next Turn.
- The provider owns what draining and retirement mean for its principal kind. A provider that also
  controls lifecycle conforms to a companion contract:

```swift skip
public protocol PrincipalLifecycleController: Sendable {
    func beginDraining(_ principal: TurnPrincipal) async throws
    func completeRetirement(_ principal: TurnPrincipal) async throws
}
```

When a principal is draining or retired, `authority(for:)` fails closed and the gate admits no new
Turn. Admitted Turns finish normally. The Agent implementation of `beginDraining` marks the durable
`.retiring` state; it then waits for attached Timelines and the private Timeline to be idle through
the runtime's idle waiter, detaches the ordinary attachments, and archives the primary Timeline
before `completeRetirement` records `.retired`.

`AgentManager` keeps the durable lifecycle states and the Agent-specific steps, but it no longer
holds an engine-internal lane that admission also uses. The `withAgent` call in `TurnPreparation`
disappears. For 7.0, the existing `AgentAuthorityCoordinator` is the Agent implementation of the
gate; only its ownership moves at 8.0.

### 5. 7.0 guardrails

7.0 adds no public principal API. These constraints keep the new 7.0 storage and the frozen shapes
from blocking 8.0:

1. **Durable owner fields use principal vocabulary.** Any new column, index, or durable field that
   names the acting owner is `principal_id` plus `principal_kind`, with `principal_kind = 'agent'`
   in 7.0. Do not add a durable `agent_id` that 8.0 must rename.
2. **New repository requirements are principal-neutral.** A 7.0 requirement that names a Turn,
   Timeline, or Workspace must not add an Agent-only parameter or an Agent-only method.
3. **Do not add a second admission branch.** Do not add a new `TurnExecutionKind` case, a second
   provider-shaped seam, or an Agent-only admission entry point.
4. **Do not add an 8.0 compatibility alias in 7.0.** No `principalID` alias property, no dual
   encoding, and no speculative public provider protocol before its 8.0 implementation.
5. **Keep the public 7.0 names.** `attachedAgentID`, `capturedAgentID`, and `agentID` stay in 7.0.
   The rename is a single 8.0 breaking change, not a 7.0 compatibility layer.

Applied to the 7.0 tickets:

- **#263, Timeline fork.** The `forkedFrom` lineage field is principal-neutral. Detachment is
  "no attached principal", not a second Agent-specific flag. `TimelineRecord.isEphemeral` stays a
  Timeline property. The new repository requirement (`deleteEphemeralTimeline(id:)`) and the start
  sweep are principal-neutral and must not add an Agent-only variant.
- **#265, `PKSQLiteStorage`.** The v1 schema column is `principal_id` (TEXT) with `principal_kind`
  (TEXT, `'agent'` in 7.0), not `agent_id`. Every table that indexes an owner uses the pair:
  `timelines`, `messages`, `turns`, and `workspace_bindings`. JSON `body` columns may carry the 7.0
  `Codable` keys; extracted and indexed columns must not. Forward-only `PRAGMA user_version`
  migrations; v1 is principal-ready so 8.0 needs no SQL migration. The product stays a runtime
  adapter with no public general-purpose SQLite API.
- **#285, quarantine release.** The facade methods and errors stay Timeline- and Turn-scoped:
  `quarantinedTurn(for:)` and `releaseQuarantine(turnID:confirmation:)`. `TurnQuarantine` and
  `QuarantineReleaseConfirmation` stay principal-neutral. Release runs through the same admission
  lane and is never keyed by Agent. `PKObservable.TimelineController` exposes quarantine state
  without an Agent reference.

## Consequences

The 8.0 split becomes a rename plus a provider implementation rather than a redesign. Agents become
one `AdmissionAuthorityProvider` above a substrate that owns Timelines, Turns, durability, and
Workspaces. The substrate never enumerates principal kinds, so a host with its own agent model
(Gnostic Ascendants, a Letta backend) supplies its own provider and kind.

The 7.0 line pays a small, deliberate cost. The SQLite v1 schema names principal columns while the
Swift model still says `agentID`, so that store carries a temporary mapping between the body and the
extracted columns. That mapping is internal to the adapter. It is cheaper than a second durable
schema migration in 8.0.

The durable scalar pair is also a small cost at call sites that want a typed principal. The
`TurnPrincipal` wrapper contains it. No call site passes a bare UUID as a principal.

A persistent risk remains for principal kinds that arrive after 8.0. The design assumes kinds stay
open and independent of the schema. A kind that later needs a dedicated durable column reopens a
storage question; this ADR does not promise one.

## Rejected alternatives

- **Keep the two execution paths and add a provider later.** It puts the riskiest seam into the
  release that freezes it, and the 8.0 extraction would redesign admission, durable records, and
  Workspace dispatch at once. The ADR is cheap; a second migration is not.
- **A closed `enum TurnPrincipal`.** The substrate would enumerate host principal kinds. Every new
  kind becomes a core release and, for storage, a schema change. An open `kind` string avoids both.
- **`principalID` without `principalKind`.** The substrate cannot distinguish an Agent from a host
  principal, and rendering or authorization cannot route on identity alone.
- **`principalKind` without `principalID`.** One kind has many identities, so authority cannot be
  scoped.
- **Keep `isPrimary` and add principals only to records.** The dispatcher's boolean is the Agent
  coupling that blocks the split. A boolean cannot express more than two Workspace kinds, and the
  binding bypass stays Agent-specific.
- **Move drain and retire into the provider with no runtime gate.** Admission and retirement would
  race, and new authority could be granted while a principal is draining. ADR 0010's capture
  immutability needs one serialization boundary.
- **Migrate legacy records inside the runtime on lookup.** ADR 0004 already rejects a second
  authority and runtime-side migration. Adapters read legacy, validate, and write canonical.
- **Ship a 7.0 compatibility alias for the future rename.** A dual encoding or alias in 7.0 would
  add the compatibility layer this design exists to avoid, and no 7.0 consumer needs it.

## Relationships

- Amends ADR 0005: execution is principal-addressed, and
  managed and direct Turns share one provider-resolved admission path.
- Amends [ADR 0004](0004-workspace-binding-and-execution-authority.md): Workspace bindings are
  principal-owned and kinded; durable ownership and per-Workspace serialization remain.
- Preserves [ADR 0010](0010-runtime-owns-turn-liveness-and-terminal-finalization.md): captured
  authority stays immutable for the Turn, and terminal finalization is unchanged.
- Uses the runtime adapter tier of [ADR 0015](0015-runtime-adapter-tier.md) for `PKSQLiteStorage`.
- Records the prerequisite for [#292](https://github.com/phynics/PositronicKit/issues/292).
