---
status: accepted
---

# Request-response generation is one terminal chunk

## Context

[Issue #236](https://github.com/phynics/PositronicKit/issues/236) adds native request-response
generation for providers and hosts that need a whole response. Streaming already feeds tool-call
accumulation, structured output, and Turn execution through `LLMStreamChunk`. A separate response
type or accumulator would require those consumers to implement the same semantics twice.

## Decision

Streaming is the canonical runtime transport. Request-response generation uses one terminal
`LLMStreamChunk` containing the complete response. A runtime adapter can yield that chunk once
and then finish the stream, so transport selection does not create a second Turn pipeline.

`PKContracts` owns `LLMClientProtocol.chatCompletion(...)` and `LLMStreamChunk.folding(_:)`.
The completion method is a protocol requirement so native provider implementations dispatch
through `any LLMClientProtocol`. Its default collects the seven-argument `chatStream` and folds
the chunks. A stream with no chunks throws `LLMServiceError.emptyResponse(provider:)`.

The fold preserves independent parallel choices and indexed tool calls within each choice.
Tool-call names and arguments concatenate because the existing delta contract permits both
fields to arrive in fragments. Collapsing all choices to index zero or keeping only the first
name fragment would discard valid output. The
[issue clarification](https://github.com/phynics/PositronicKit/issues/236#issuecomment-5972240461)
records these differences from the original folding table.

Providers own their HTTP request-response implementations and reuse their streaming request
builders and response mappings. Native completion calls retry transient failures before returning
the response. The `sendMessage` default delegates to completion and adds no retry loop.
`PKContracts` and provider products do not import runtime transport policy.

## Consequences

One response representation carries text, reasoning, generated audio, complete tool calls,
finish reasons, and usage across both provider transports. FoundationModels and custom clients
can use the stream-fold default without implementing a native endpoint.

Phase 1 supplies the contracts and native provider calls. Runtime transport selection and its
single-chunk stream adapter belong to phase 2 of issue #236. Until that phase ships, Turns and
`kit.model` continue to call streaming APIs.

Folding buffers the streamed chunks before returning. Native implementations avoid that buffer
and can use request-response endpoints without SSE support.

## Rejected alternatives

- A separate completion response type would duplicate mapping and accumulation semantics.
- A second Turn execution pipeline would duplicate tool routing, structured-output handling,
  and durability rules.
- An extension-only completion method would bypass native implementations when callers hold
  a protocol existential.
