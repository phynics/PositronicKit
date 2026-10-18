# PositronicKit Context Map

PositronicKit is composed of three named contexts. Each context owns a distinct vocabulary;
relationships between them are translation boundaries, not shared ownership.

## Contexts

- [PositronicKit runtime](Sources/PositronicKit/CONTEXT.md) — durable Timelines, Turns, Agents,
  Workspaces, Sidecars, and execution authority.
- [PKPrompt](Sources/PKPrompt/CONTEXT.md) — optional prompt authoring: composition, assembly,
  rendering, and journaling.
- [PKContracts](Sources/PKContracts/CONTEXT.md) — provider-neutral model messages, tool
  definitions, calls and results, embedding contracts, structured output, and diagnostics.

## Relationships

- **PKPrompt / providers → PKContracts**: these lower-level products consume
  runtime-neutral contracts without owning runtime entities; PKContracts points inward to no
  PositronicKit project module.
- **PKPrompt → PKUtilities**: the optional authoring product consumes the shared prompt section
  model, token budgeting, compression, and journal-support values from the package-internal
  `PKUtilities` target and re-exports them.
- **PositronicKit → PKContracts + PKUtilities**: the runtime owns Turn, Agent, Workspace, and
  Sidecar values. It composes the model and tool contracts with its internal tiered `PromptLayout`.
  It does not import `PKPrompt` or redefine the leaf vocabulary.
- **Observation / examples / integrations → PositronicKit**: outward-facing layers consume the
  runtime capabilities without owning orchestration internals.
- **Gnostic adapter → PositronicKit**: Gnostic’s downstream domain term maps to a PositronicKit
  Timeline only at Gnostic’s adapter boundary.

## Glossary rule

Each linked context is glossary-only: entries define ownership and meaning in one or two sentences,
then give exact `_Avoid_` lines for misleading synonyms. Retired vocabulary may appear only on an
exact glossary `_Avoid_` line; issue #73’s semantic checker must treat that line form as the required
exception.

PKContracts is a leaf context: it owns no Timeline, Turn, Agent, Workspace binding, repository, or
orchestration concept. Runtime events, snapshots, and entities live in `PositronicKit`, even when
their payloads use `PKContracts` values.
