# PositronicKit Context Map

PositronicKit is composed of three named contexts. Each context owns a distinct vocabulary;
relationships between them are translation boundaries, not shared ownership.

## Contexts

- [PositronicKit runtime](Sources/PositronicKit/CONTEXT.md) — durable Threads, Turns, Agents,
  Workspaces, and execution authority.
- [PKPrompt](Sources/PKPrompt/CONTEXT.md) — prompt composition, assembly, rendering, and
  journaling.
- [PKContracts](Sources/PKContracts/CONTEXT.md) — provider-neutral messages, model clients,
  tools, structured output, and diagnostics.

## Relationships

- **PKPrompt / providers → PKContracts**: these lower-level products consume
  runtime-neutral contracts without owning runtime entities; PKContracts points inward to no
  PositronicKit project module.
- **PositronicKit → PKContracts + PKPrompt**: the runtime composes model contracts and prompt
  artifacts into Turns; it does not redefine either vocabulary.
- **Observation / examples / integrations → PositronicKit**: outward-facing layers consume the
  runtime capabilities without owning orchestration internals.
- **Gnostic adapter → PositronicKit**: Gnostic’s downstream domain term maps to a PositronicKit
  Thread only at Gnostic’s adapter boundary.

## Glossary rule

Each linked context is glossary-only: entries define ownership and meaning in one or two sentences,
then give exact `_Avoid_` lines for misleading synonyms. Retired vocabulary may appear only on an
exact glossary `_Avoid_` line; issue #73’s semantic checker must treat that line form as the required
exception.

PKContracts is a leaf context: it owns no Thread, Turn, Agent, Workspace binding, repository, or
orchestration concept.
