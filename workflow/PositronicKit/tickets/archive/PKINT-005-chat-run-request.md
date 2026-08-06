# PKINT-005 — Replace the run() Positional Parameter List With a Request Value to Eliminate Silent-Drop Footguns

**Priority:** P2
**Type:** API ergonomics / regression-prevention
**Depends on:** None
**Blocks:** Safe evolution of the run surface
**Surfaced by:** YAK-1, YAK-12 (Yakamoz)
**Status:** Completed 2026-07-04 (`PositronicKit` commit `27c4122`)

### Summary

Collapse `PositronicKit.run(...)`'s ten defaulted positional parameters into a single
`ChatRunRequest` value type so that adding, removing, or omitting a field is explicit and
greppable, and a dropped argument cannot silently change behavior. YAK-12 deleted the
ambiguous overload; this removes the underlying shape that made the footgun possible.

### Current Problem

YAK-1/YAK-12: `structuredOutput:` was silently dropped from a call site, still compiled
(resolved to a different overload), and typed replies quietly stopped sending their schema.
The overload was collapsed (`Sources/PositronicKit/PositronicKit.swift:246` is now the single
`run`), but the function still has **ten** parameters, nine of them defaulted:

```swift
public func run(
    timelineId: UUID,
    message: String,
    tools: [AnyTool] = [],
    toolOutputs: [ToolOutputSubmission]? = nil,
    systemInstructions: String? = nil,
    agentInstanceId: UUID? = nil,
    maxTurns: Int = 5,
    generationParameters: GenerationParameters? = nil,
    structuredOutput: StructuredOutputRequest? = nil,
    promptAssemblyLogger: Logger? = nil
) async throws -> AsyncThrowingStream<ChatEvent, Error>
```

A long defaulted-parameter list is exactly the surface where the next field is silently
omittable. A request struct makes every field a named, type-checked member and makes "what did
this call site pass?" a single value to inspect/log.

### Files

- Add: `Sources/PositronicKit/...` `ChatRunRequest` value type (Sendable).
- Modify: `Sources/PositronicKit/PositronicKit.swift` (`run`) — replace the parameter list
  outright with `run(_ request: ChatRunRequest)`.
- Modify: `Sources/PositronicKitExamples/...` to use the request value.
- Modify: `Monad`/`Shuttle`/Yakamoz call sites (`YakamozRuntime.run` → `kit.run`).
- Modify: the `ChatRunning` protocol and its conformers (`YakamozRuntime`, `FollowUpRunner`)
  to match the new signature.

### Implementation Requirements

1. Introduce `ChatRunRequest` (Sendable) with `timelineId`/`message` required and the rest as
   members with the current defaults. Provide a memberwise init.
2. Make `run(_ request: ChatRunRequest)` the **only** API — delete the parameter-list `run`.
   Migrate every in-workspace call site (`PositronicKitExamples`, `Monad`, `Shuttle`,
   `YakamozRuntime`/`FollowUpRunner`) and the `ChatRunning` protocol in the same change. No
   deprecated shim.
3. `ChatRunRequest` should be cheaply loggable (`CustomStringConvertible` or a redacted
   summary) so a call site's exact configuration can be captured — directly useful for the
   kind of diagnosis YAK-23 needed.
4. No behavioral change for any field; this is a shape change only.

### Required Tests

- A test constructs a `ChatRunRequest`, runs through a mock, and asserts each field is honored
  (especially `structuredOutput`, the YAK-1 regression — assert the schema reaches the
  transport, mirroring the existing `StructuredOutputRunTests` guard).
- A test asserts a `ChatRunRequest` built with only the required fields applies the same
  defaults the old parameter list did (guards the migration against a changed default).

### Acceptance Criteria

- [x] `run` takes a single `ChatRunRequest`; no defaulted-parameter pile remains as the
      primary surface.
- [x] The structured-output regression guard passes against the new shape.
- [x] `PositronicKitExamples` and all `Monad`/`Shuttle`/Yakamoz call sites use the request value.
- [ ] `make verify` green; downstream builds green.

### Landed Notes

- Added transport-neutral `ChatRunRequest` as the sole public `PositronicKit.run(_:)` entrypoint.
- Removed the old positional `run(...)` overload instead of leaving a deprecated shim in place.
- Migrated `PositronicKitExamples`, `Monad`, `Shuttle`, `YakamozRuntime`, `FollowUpRunner`, and
  the `ChatRunning` seam to pass a request value.
- `ChatRunRequest` now carries a concise `description` for logging / diagnostics.

### Verification Notes

- Verified locally in `PositronicKit`: `swift test` passed on 2026-07-04, including
  `StructuredOutputRunTests`.
- Downstream code was migrated in-repo, but direct consumer verification in this environment was
  blocked by SwiftPM/Xcode sandbox permission failures before normal build execution.

### Handoff Notes

The goal is that a future field cannot be "dropped" — it is either set on the request or it is
the explicit default, and a code review sees the whole request at one call site. Keep
`ChatRunRequest` free of provider-specific types so it stays transport-neutral.
