# PositronicKit Runtime Context

The runtime context owns durable agentic execution: a Turn runs on a Thread, with optional Agent
continuity and authorized Workspace execution.

## Domain

**Thread**:
A durable ordered history and execution container. A Thread may be detached or attached to at most
one Agent, and its history remains owned by the Thread.
_Avoid_: Timeline, runtime Timeline

**Turn**:
One caller request and all model/tool rounds until one terminal outcome.
_Avoid_: chat run, send

**Model Round**:
One provider interaction within a Turn. Tool continuation creates another Model Round in the same
Turn.
_Avoid_: turn count, nested Turn

**Agent**:
A persistent identity and continuity entity that participates through Threads. An Agent is not an
independently callable execution target.
_Avoid_: AgentInstance, agent run

**Agent Context Source**:
The authoritative replaceable supplier of typed Agent continuity captured for a managed Turn.
It may be filesystem-backed, database-backed, remote, hybrid, or deliberately memory-free.
_Avoid_: global memory pipeline, prompt plugin

**Agent Context Snapshot**:
The immutable identity, instructions, continuity items, optional primary-Thread summary, and
revision metadata captured for one managed Turn.
_Avoid_: live Agent state, mutable prompt context

**Agent Lifecycle**:
The durable active, retiring, or retired state that controls managed Turn admission and the
drain-to-purge lifecycle of an Agent’s primary resources.
_Avoid_: Agent deletion as normal shutdown

**Workspace**:
A host-owned execution and storage boundary. Ordinary Workspaces bind exclusively to Threads;
an Agent’s primary Workspace is permanently Agent-owned.
_Avoid_: tool bag, workspace array

**WorkspaceReference**:
The durable identity and metadata snapshot for a Workspace. It is the runtime’s persisted model;
it does not imply that the workspace is local, filesystem-backed, or currently connected.
_Avoid_: live workspace, workspace implementation

**WorkspaceProvider**:
A live host adapter for a `WorkspaceReference`. It supplies reachability and may opt into
`WorkspaceToolProvider` or `WorkspaceFileProvider` independently, so non-filesystem and
non-tool workspaces remain valid.
_Avoid_: workspace record, universal workspace protocol

**Workspace Binding**:
The durable exclusive relationship between one ordinary Workspace and one Thread. A Thread may
hold many bindings; Agent primary Workspace ownership is not a binding.
_Avoid_: mutable Thread workspace list, shared workspace claim

**Workspace Execution Lane**:
A process-local FIFO coordinator that prevents overlapping execution for one Workspace while
allowing independent Workspaces to execute concurrently.
_Avoid_: distributed lock, global execution queue

**Thread Execution Context**:
The authority-bearing Agent, Workspace, catalog, and related configuration captured when a Turn is
admitted. It remains immutable while that Turn is active.
_Avoid_: live prompt state, mutable run context

## Execution

**Managed Turn**:
A Turn admitted from an Agent-attached Thread; the runtime derives and captures the Agent context.
_Avoid_: implicit Agent run

**Direct Turn**:
A consumer-controlled Turn admitted only on a detached Thread with explicit system/context input.
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

**Thread Runtime Repository**:
The single transactional owner of Thread metadata, append-only history, Turn admission with its
input message, tool intent/results, terminal outcomes, and stale-Turn recovery.
_Avoid_: persistence coordinator, prompt journal

## History and continuity

**Thread Message**:
An append-only durable record belonging to a Thread and correlated to a Turn.
_Avoid_: ConversationMessage

**Thread Summary**:
A semantic projection over a covered history range; it is not a message role and does not replace
the covered messages.
_Avoid_: summary message

**PromptJournal**:
PKPrompt’s cache and emission state for an assembled prompt. It observes semantic history but does
not create or own Thread summaries.
_Avoid_: runtime history, summary store

**Tool Intent**:
A durable declaration of a tool call associated with a Turn and Model Round, recorded before the
corresponding tool execution begins.
_Avoid_: tool request event, callable Agent

**Tool Result**:
A durable outcome for a previously recorded Tool Intent, available to later Model Rounds without
re-executing the tool.
_Avoid_: tool replay, transient tool output
