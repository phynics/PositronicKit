# PositronicKit Runtime Context

The runtime context owns durable agentic execution: a Turn runs on a Timeline, with optional Agent
continuity and authorized Workspace execution.

## Domain

**Timeline**:
A durable ordered history and Turn-admission scope. Its persisted metadata value is a
`TimelineRecord`; its identity-bound execution interface is a `TimelineHandle`.
_Avoid_: session

**Turn**:
One caller request and all model/tool rounds until one terminal outcome.
_Avoid_: chat run, send

**Model Round**:
One provider interaction within a Turn. PKTool continuation creates another Model Round in the same
Turn.
_Avoid_: turn count, nested Turn

**Turn Identity**:
The Turn UUID, optional Request ID, and model-round index that identify one Turn and its current
model interaction.
_Avoid_: Timeline identity, message identity

**Turn Event**:
A runtime notification about streamed output, tool activity, errors, or Turn completion. Events are
not Timeline history.
_Avoid_: durable message, Timeline record

**Turn Snapshot**:
A serializable diagnostic projection of one Turn's context, model output, tool activity, and
performance metrics.
_Avoid_: Timeline history, live Turn state

**Turn Context Snapshot**:
The ordered prompt messages assembled for a Turn, stored as a serializable value.
_Avoid_: live execution context, Agent context snapshot

**Agent**:
A persistent identity and continuity entity that participates through Timelines. An Agent is not an
independently callable execution target.
_Avoid_: AgentInstance, agent run

**Agent Template**:
Creation-time instructions and optional workspace-file seeds used to create an Agent.
_Avoid_: live Agent, Agent context source

**Agent Context Source**:
The authoritative replaceable supplier of typed Agent continuity captured for a managed Turn.
It may be filesystem-backed, database-backed, remote, hybrid, or deliberately memory-free.
_Avoid_: global memory pipeline, prompt plugin

**Agent Context Snapshot**:
The immutable identity, instructions, continuity items, optional primary-Timeline summary, and
revision metadata captured for one managed Turn.
_Avoid_: live Agent state, mutable prompt context

**Agent Lifecycle**:
The durable active, retiring, or retired state that controls managed Turn admission and the
drain-to-purge lifecycle of an Agent’s primary resources.
_Avoid_: Agent deletion as normal shutdown

**Request Origin**:
A registered requester identity known to the runtime, with a host name, display name, and platform.
_Avoid_: tool origin, Workspace provider

**Workspace**:
A host-owned execution and storage boundary. Ordinary Workspaces bind exclusively to Timelines;
an Agent’s primary Workspace is permanently Agent-owned.
_Avoid_: tool bag, workspace array

**WorkspaceReference**:
The durable identity and metadata snapshot for a Workspace. It is the runtime’s persisted model;
it does not imply that the workspace is local, filesystem-backed, or currently connected.
_Avoid_: live workspace, workspace implementation

**Workspace URI**:
A parsed address for a Workspace in a host-defined scheme. It identifies the resource without
claiming that the resource is local or reachable.
_Avoid_: filesystem path, Workspace reference

**Workspace Tool Candidate**:
An authorized Workspace tool captured for one Turn's ambiguity correction and dispatch.
_Avoid_: available tool list, live Workspace catalog

**Workspace Tool Routing**:
Whether the runtime selected a Workspace explicitly from the request or implicitly from one match.
_Avoid_: distributed routing, provider routing

**WorkspaceProvider**:
A live host adapter for a `WorkspaceReference`. It supplies reachability and may opt into
`WorkspaceToolProvider` or `WorkspaceFileProvider` independently, so non-filesystem and
non-tool workspaces remain valid.
_Avoid_: workspace record, universal workspace protocol

**Workspace Binding**:
The durable exclusive relationship between one ordinary Workspace and one Timeline. A Timeline may
hold many bindings; Agent primary Workspace ownership is not a binding.
_Avoid_: mutable Timeline workspace list, shared workspace claim

**Workspace Execution Lane**:
A process-local FIFO coordinator that prevents overlapping execution for one Workspace while
allowing independent Workspaces to execute concurrently. When a mutating or external-process tool
times out but may still run, the lane stays closed until that abandoned task ends, so a later call
for the same Workspace cannot overlap it.
_Avoid_: distributed lock, global execution queue

**Timeline Execution Context**:
The authority-bearing Agent, Workspace, catalog, and related configuration captured when a Turn is
admitted. It remains immutable while that Turn is active.
_Avoid_: live prompt state, mutable run context

## Execution

**Managed Turn**:
A Turn admitted from an Agent-attached Timeline; the runtime derives and captures the Agent context.
_Avoid_: implicit Agent run

**Direct Turn**:
A consumer-controlled Turn admitted only on a detached Timeline with explicit system/context input.
_Avoid_: unmanaged chat, raw model call

**Turn ID**:
The unique identity of one admitted execution.
_Avoid_: send ID, message ID

**Request ID**:
An optional caller-owned idempotency key whose fingerprint identifies request intent.
_Avoid_: execution ID, message ID

**Turn Outcome**:
The terminal truth for a Turn: completed, failed, cancelled, or interrupted, with any durable
diagnostic or terminal handle associated with that result.
_Avoid_: stream finished, best-effort completion

**Turn Diagnostic**:
Host-visible metadata for a dependency that was unavailable during Turn preparation.
_Avoid_: log message, Turn outcome

**Sidecar Directive**:
An optional structured-output field requested with a Turn, including its schema and delivery policy.
_Avoid_: model tool call, provider tool

**Sidecar Delta**:
A streamed update for one Sidecar Directive field.
_Avoid_: Turn text delta, tool-call delta

**Sidecar Result**:
The parsed value, decline, or failure for one Sidecar Directive.
_Avoid_: Tool Result, Turn outcome

**Sidecar Completion**:
The identified set of Sidecar Results committed for one model round or terminal Turn.
_Avoid_: Turn completion event, Timeline message

**Timeline Runtime Repository**:
The single transactional owner of Timeline metadata, append-only history, Turn admission with its
input message, tool intent/results, terminal outcomes, and stale-Turn recovery. It loads a
``TurnLedgerSnapshot`` and commits a ``TurnLedgerCommit`` atomically; the transition rules live in
the Turn Ledger.
_Avoid_: persistence coordinator, prompt journal

**Turn Ledger**:
The runtime-owned, storage-free decision module for every durable Turn transition. A pure decision
reads a ``TurnLedgerSnapshot`` and returns the rows to write; the repository applies them in one
transaction.
_Avoid_: turn state machine, in-memory repository

## History and continuity

**Timeline Message**:
An append-only durable record belonging to a Timeline and correlated to a Turn.
_Avoid_: ConversationMessage

**Timeline Summary**:
A semantic projection over a covered history range; it is not a message role and does not replace
the covered messages.
_Avoid_: summary message

**PKTool Intent**:
A durable declaration of a tool call associated with a Turn and Model Round, recorded before the
corresponding tool execution begins.
_Avoid_: tool request event, callable Agent

**PKTool Result**:
A durable outcome for a previously recorded PKTool Intent, available to later Model Rounds without
re-executing the tool.
_Avoid_: tool replay, transient tool output
