# PKContracts Context

PKContracts owns the runtime-neutral vocabulary shared by model providers and prompt consumers. It
is a leaf context and does not own runtime orchestration.

## Model interaction

**Model Message**:
A provider-neutral request or response message with ordered content and role semantics.
_Avoid_: Timeline Message, TimelineMessage

**Modality**:
A supported form of model content, such as text, image, audio, or structured data.
_Avoid_: provider-specific payload type

**Model Client**:
A replaceable capability for generation, streaming, and structured inference.
_Avoid_: Turn engine, TurnEngine

**Generation Parameters**:
Caller-selected model options that are part of an inference request.
_Avoid_: runtime policy

## Embeddings

**Embedding**:
A vector together with the `EmbeddingSpace` it belongs to. Two embeddings are comparable only when
their spaces are equal.
_Avoid_: anonymous vector, raw `[Float]`

**Embedding Space**:
The provider, model, dimension count, and normalization that make an embedding comparable.
_Avoid_: model name string, vector store

**Embedding Client**:
A runtime-neutral capability that turns text into embeddings and declares its input budget.
_Avoid_: retrieval service, memory store

**Embedding Input Budget**:
The text-count, per-text byte, and total-byte limits an Embedding Client admits before I/O.
_Avoid_: tokenizer

## Tools and structured output

**Tool Definition**:
The provider-neutral name, description, and schema for a callable capability.
_Avoid_: Workspace binding

**Tool Call**:
A model-issued request to invoke a named tool with arguments and an independent call identity.
_Avoid_: Turn, Model Round

**Tool Result**:
The provider-neutral success or failure value returned for one Tool Call.
_Avoid_: TurnOutcome

**Structured Output**:
A schema-constrained model result contract independent of runtime persistence or orchestration.
_Avoid_: Codable runtime entity

## Diagnostics

**Diagnostic Value**:
A bounded, redaction-compatible value suitable for cross-module error or notice details.
_Avoid_: unbounded payload, internal Error object
