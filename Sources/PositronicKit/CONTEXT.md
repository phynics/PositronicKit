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

**Workspace**:
A host-owned execution and storage boundary. Ordinary Workspaces bind exclusively to Threads;
an Agent’s primary Workspace is permanently Agent-owned.
_Avoid_: tool bag, workspace array

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
