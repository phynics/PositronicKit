# PKPrompt Context

PKPrompt owns the structural language for composing, validating, rendering, and journaling model
prompts. It does not own runtime entities, persistence, provider transport, or orchestration.

## Composition

**Prompt**:
A composable value describing a prompt subtree.
_Avoid_: runtime context, message pipeline

**PromptNode**:
The canonical internal intermediate representation produced from Prompt values.
_Avoid_: provider message, Thread history

**PromptBuilder**:
The result-builder surface used to compose Prompt values from structural children.
_Avoid_: runtime builder

**Prompt Section**:
A named, role-bearing unit of assembled prompt content with inherited traits resolved at assembly.
_Avoid_: message record, arbitrary plugin payload

**Prompt Assembly**:
The validation and lowering step that turns Prompt composition into an assembled artifact.
_Avoid_: model request, Turn admission

**Assembled Prompt**:
The validated section artifact ready for canonical rendering.
_Avoid_: provider payload

**Rendered Prompt**:
The canonical rendered output consumed by a model client or journal.
_Avoid_: raw prompt string

## Stability and journaling

**Stability**:
The lifecycle classification that determines whether prompt content is stable, semi-stable, or
volatile for caching and emission.
_Avoid_: persistence durability

**Compression**:
A prompt-specific transformation or metadata policy applied during assembly.
_Avoid_: model retry, history compaction

**PromptJournal**:
State that tracks rendered prompt emission and cache transitions. It can be discarded and rebuilt
without changing runtime meaning.
_Avoid_: ThreadRuntimeRepository, semantic summary
