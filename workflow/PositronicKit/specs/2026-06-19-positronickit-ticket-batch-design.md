# PositronicKit Ticket Batch Design

## Scope

This batch covers eight approved tickets across provider transports, retry policy, unconfigured runtime behavior, runtime tool defaults, documentation accuracy, API stability, and Linux validation.

## Execution Order

1. Ticket 1: classify provider HTTP failures and retry behavior.
2. Ticket 2: remove crashing and hanging paths from `UnconfiguredLLMService`.
3. Ticket 3: add injectable provider transports and shared provider contract tests.
4. Ticket 4: reconcile README, DocC, guides, and CI documentation validation.
5. Ticket 5: define and enforce the public API stability policy.
6. Ticket 6: add Linux validation for transport-neutral products.
7. Ticket 7: make default runtime tool installation configurable.
8. Ticket 8: make OpenRouter attribution configurable.

## Design

### Provider retry and transport

Introduce a shared HTTP-aware error surface for provider adapters so retry decisions can distinguish between transient transport failures and permanent HTTP failures. The shared transport contract will allow deterministic request/response injection for `OpenAI`, `OpenRouter`, and `Ollama` tests without real networking. `RetryPolicy` will honor `Retry-After`, preserve cancellation, and only retry provider failures that are explicitly transient.

### Unconfigured runtime behavior

`UnconfiguredLLMService` will stop using `fatalError` and will instead fail all throwing operations with `LLMServiceError.notConfigured`. Streaming APIs will terminate immediately with the same error so direct callers do not hang. Any helper that currently assumes schema construction cannot fail will use a non-crashing fallback.

### Runtime tool defaults

`TimelineManager` will gain a public runtime tool policy value that centralizes installation of default filesystem, timeline-observation, and timeline-send tools. Existing behavior remains the default. Hosts will be able to deny all defaults or selectively disable categories without bypassing agent-dependent `timeline_send` checks.

### Documentation, API policy, and Linux validation

Documentation will be updated to reflect the current facade-centered architecture and actual shipped persistence/runtime boundaries. CI will validate compiled examples and DocC. The package will explicitly define its compatibility policy, track a reviewed public API baseline, and validate transport-neutral targets on Linux while clearly excluding unsupported provider products.

## Constraints

- Keep public provider initialization source-compatible.
- Keep error messages user-friendly and avoid leaking credentials.
- Preserve current defaults unless a ticket explicitly changes configurability.
- Avoid real network use in tests.
- Keep concurrency and cancellation behavior explicit and test-covered.
