# Provider capability matrix

This table is published from and validated against the executable manifest at
`Tests/PKTestSupport/Fixtures/ProviderCapabilityMatrix.json`. Run `make verify-documentation` after
changing either the manifest or this table.

The common request types remain provider-neutral. Optional generation settings may degrade with
a structured warning. Media is strict: callers must explicitly enable the model capability and
unsupported media or an unrepresentable content order fails before prompt journaling, persistence,
or provider I/O. PositronicKit accepts caller-resolved `Data` and never loads media from a file or
URL.

| Provider | Image input | Audio input | Audio output | Prompt caching | Layout notes |
| --- | --- | --- | --- | --- | --- |
| OpenAI | Ordered content parts | Ordered WAV/MP3 parts | Typed streamed deltas with transcript | Automatic; routing key, and model-dependent retention | Capabilities must be explicitly configured, including for OpenAI-compatible endpoints |
| OpenRouter | Ordered content parts | Ordered WAV/MP3 parts | Typed streamed deltas with transcript | Automatic; explicit cache_control for anthropic/*, session routing key | Actual model support remains route-dependent |
| Anthropic | Ordered base64 image blocks | Rejected | Rejected | Explicit; cache_control on at most four tier breakpoints | Text and image block order is preserved |
| Ollama | Base64 image arrays | Rejected | Rejected | None; keep_alive governs model residency only | Mixed text/image layouts are rejected because the wire format cannot preserve relative order |
| Foundation Models | Disabled | Disabled | Disabled | None; prewarm(promptPrefix:) semantics unconfirmed | Remains disabled until a native mapping exists |

Generated audio is persisted inline with its transcript. A valid provider continuation reference
may be used for recent model-facing history. After expiry or compaction, history falls back to the
transcript while persisted bytes remain available for playback. Diagnostic snapshots retain only
audio format, byte count, and transcript, not binary data.

Warnings never include prompts, tool arguments, or response content.
