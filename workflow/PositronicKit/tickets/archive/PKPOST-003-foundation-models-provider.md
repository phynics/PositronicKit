# PKPOST-003: Foundation Models provider adapter (Apple on-device models)

**Priority:** P3 (post-v1 roadmap; user direction 2026-07-05, scope narrowed same day)
**Type:** Feature — new provider target
**Depends on:** PKREL-004; PKINT-001 (stream-decoding contract applies to the synthesized chunk sequence)
**Blocks:** None
**Status:** Done — 2026-07-05. `PKFoundationModelsProvider` shipped as a guarded library
product: `FoundationModelsClient` maps `LanguageModelSession` streaming onto
`LLMStreamChunk` through a `FoundationModelsSessioning` abstraction seam (unit-tested with
scripted fake sessions — no live Apple Intelligence needed), `FoundationModelsToolBridge`
converts PositronicKit tools into the framework's tool protocol (the session executes tools
itself), guardrail/termination outcomes map to typed `FinishReason`, and
`SystemLanguageModel.availability` surfaces as a typed `PKError` with user-actionable
guidance ("enable Apple Intelligence in System Settings"), never a crash or empty stream.
`#if canImport(FoundationModels)` gating keeps the package green on Linux/pre-26 hosts,
where `chatStream` throws a typed unsupported-platform error. `PositronicKit(foundationModelsTools:)`
convenience init added — with NO default parameter value, after the review gate caught that a
fully-defaulted list made bare `PositronicKit()` silently resolve to this initializer
(`RuntimeSetupStoriesTests` regression). 25 new tests in 4 suites; `make verify` green at
786 tests / 146 suites; `make verify-products` green. Example, README support-matrix row,
and CHANGELOG entry added. Deferred with reason: the live end-to-end smoke on real Apple
Intelligence could not run in this environment (framework availability not exercisable in
the sandboxed test host); the mapping/bridge/availability layers are fully unit-tested
against the session seam instead.

### Summary

Add Apple's on-device **Foundation Models framework** (`import FoundationModels`, Apple
Intelligence system models) as a PositronicKit provider — a new library product
(`PKFoundationModelsProvider`) alongside `PKOpenAIProvider`/`PKOllamaProvider`, kept out of
the core runtime target. No API key, no network. Scope is exactly "Foundation Models as a
provider" — nothing broader (no CoreML/MLX model hosting, no other Apple-framework
integrations).

### Adapter notes (differs from the HTTP adapters)

- `LanguageModelSession` is a Swift session API, not a wire protocol: the adapter maps
  session streaming into `LLMStreamChunk`/`ChatEvent` deltas itself. PKINT-001 conformance
  applies to the synthesized chunk sequence — fixture on recorded session transcripts, not
  captured wire bytes.
- Tool calling bridges PositronicKit `Tool`/`parametersSchema` to the framework's typed
  `Tool` protocol (`@Generable` schemas), preserving call/result id pairing (PKINT-002).
- Map termination/guardrail outcomes into the typed `FinishReason` vocabulary (PKR-13);
  map `GenerationParameters` where knobs exist, document what's ignored.
- **Availability gating:** macOS 26+/Apple Silicon with Apple Intelligence enabled.
  `SystemLanguageModel.availability` surfaces as a typed `PKError` with a
  `userFriendlyMessage` (e.g. "enable Apple Intelligence in System Settings") — never a
  crash or silent empty stream. `#if canImport(FoundationModels)`-guard the product so the
  package stays green on Linux and pre-26 macOS.
- Small on-device context window and session prewarming characteristics — document in the
  README support-matrix row.

### Implementation Requirements

1. New guarded library product; whole package builds/tests green on hosts without the
   framework.
2. Streaming + tool-calling conformance tests over recorded session streams (text,
   multi-tool, guardrail refusal, context-exceeded).
3. `PKTestSupport` fixtures + a `PositronicKitExamples` example; README support-matrix row;
   changelog entry.
4. Downstream-sync checklist on any shared-type touches; Yakamoz's provider picker gains
   the on-device option when it repins.

### Acceptance Criteria

- [ ] `PKFoundationModelsProvider` builds as a separate product; package remains green on
      hosts without FoundationModels.
- [ ] Streaming text + tool-calling turn works end-to-end in `PositronicKitExamples` on a
      supported host.
- [ ] Unavailability surfaces as a typed, user-friendly PKError.
- [ ] Conformance/regression tests green; `make verify` green.
