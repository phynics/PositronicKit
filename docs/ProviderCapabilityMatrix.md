# Provider capability matrix

The common request surface remains provider-neutral. Optional generation settings may degrade with
a structured warning, but media is strict: callers must explicitly enable the model capability and
unsupported media or an unrepresentable content order fails before prompt journaling, persistence,
or provider I/O. PositronicKit accepts caller-resolved `Data` and never loads media from a file or
URL.

| Provider | Image input | Audio input | Audio output | Layout notes |
| --- | --- | --- | --- | --- |
| OpenAI | Ordered content parts | Ordered WAV/MP3 parts | Typed streamed deltas with transcript | Capabilities must be explicitly configured, including for OpenAI-compatible endpoints |
| OpenRouter | Ordered content parts | Ordered WAV/MP3 parts | Typed streamed deltas with transcript | Actual model support remains route-dependent |
| Anthropic | Ordered base64 image blocks | Rejected | Rejected | Text and image block order is preserved |
| Ollama | Base64 image arrays | Rejected | Rejected | Mixed text/image layouts are rejected because the wire format cannot preserve relative order |
| Foundation Models | Disabled | Disabled | Disabled | Remains disabled until a native mapping exists |

Generated audio is persisted inline with its transcript. A valid provider continuation reference
may be used for recent model-facing history; after expiry or compaction, history falls back to the
transcript while persisted bytes remain available for playback. Diagnostic snapshots retain only
audio format, byte count, and transcript—not binary data.

Warnings never include prompts, tool arguments, or response content.
