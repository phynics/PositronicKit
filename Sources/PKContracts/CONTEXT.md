# PKContracts Context

PKContracts owns the runtime-neutral vocabulary shared by model providers, prompt consumers, and
embedding implementations. It is a leaf context and does not own runtime orchestration.

## Model interaction

**Model Message**:
A provider-neutral request or response message with ordered content and role semantics.
_Avoid_: Thread Message, ThreadMessage

**Modality**:
A supported form of model content, such as text, image, audio, or structured data.
_Avoid_: provider-specific payload type

**Model Client**:
A replaceable capability for generation, streaming, and structured inference.
_Avoid_: Turn engine, TurnEngine

**Generation Parameters**:
Caller-selected model options that are part of an inference request.
_Avoid_: runtime policy

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

**Embedding**:
A provider-neutral vector representation contract used by an embedding implementation or consumer.
_Avoid_: mandatory Agent memory

## Diagnostics

**Diagnostic Value**:
A bounded, redaction-compatible value suitable for cross-module error or notice details.
_Avoid_: unbounded payload, internal Error object
