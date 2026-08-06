# PKAPI-004 — `ChatEvent` enum ergonomics: `.failed`/`.failure` collision, double-nesting, hardcoded `.blocked` set

**Priority:** P2
**Type:** API design
**Depends on:** —
**Blocks:** —
**Triage:** ready-for-agent
**Status:** Done (2026-07-09, commit `6516ed5`, merged into `main`) — `ToolExecutionStatus.failure`
renamed to `.executionError` (`.failed`/`ToolResult.failure` untouched, no collision). `ChatEvent`'s
`delta`/`meta`/`error`/`completion` cases flattened to unlabeled payloads; all in-repo pattern
matches updated. Blocked-error classification moved onto `PKError.isBlocked` (default `false`,
overridden `true` on the four blocked-condition error cases); `ErrorIdentity` now carries a derived
`isBlocked` field (Equatable/Hashable still identity-only on domain+code; Codable decodes with a
`false` default for back-compat) replacing the hand-curated `static let blocked` set. Downstream
grep documented in the CHANGELOG entry (Monad/Shuttle/Yakamoz not edited — migration deferred to
their next PositronicKit pin bump, consistent with the workspace's pin-based release model).
`make verify` green (932 tests / 159 suites on `main` after merge). CHANGELOG updated (Breaking).

### Summary

Three confirmed issues, all in `Sources/PKShared/SharedTypes/ChatEvent.swift`:

1. **`.failed` vs `.failure` name collision.** `ToolExecutionStatus` has both
   `case failed(reference: ToolReference, error: String)` (line 7) and
   `case failure(String)` (line 8) — two near-synonym case names for structurally
   different payloads. `ToolResult.failure(_:)` (`ToolResult.swift:21`) reuses the same
   word again for a third, unrelated static factory. A consumer can't tell from the name
   alone which variant/type they're matching.
2. **Double-nesting with redundant `event:` labels.** `ChatEvent` wraps every category in
   a single-payload case with a matching label:
   `case delta(event: DeltaEvent)`, `case meta(event: MetaEvent)`, `case error(event: ErrorEvent)`,
   `case completion(event: CompletionEvent)` (lines ~108-111). The `event:` label repeats
   the case name and adds nothing; consumers must double-pattern-match
   (`if case .delta(let event) = self, case .generation(let text) = event`). The
   existence of flattening factory shortcuts (`.thinking(_:)`, `.generation(_:)`) and
   computed properties (`textContent`, `thinkingContent`) is itself evidence the nesting
   is awkward enough that the codebase already routes around it.
3. **`ErrorIdentity.blocked` is a hand-curated magic-code set.** (lines ~227-248) A
   `Set<ErrorIdentity>` of hardcoded `(domain, code)` pairs classifies which errors count
   as "blocked." Adding a new blocked-error type means remembering to edit this set by
   hand — the classification lives structurally far from the error types themselves
   (`PKErrorDomain.tool` code 210/207, `.filesystem` code 101, `.workspace` code 3002).

### Implementation Requirements

- [ ] Rename `ToolExecutionStatus.failed`/`.failure` to be self-distinguishing, e.g.
      `.failed(reference:error:)` stays, `.failure(String)` → `.executionError(String)` or
      similar — pick names that read distinctly at the call site without needing to check
      the payload shape.
- [ ] Flatten `ChatEvent`'s wrapper cases: `case delta(DeltaEvent)`, `case meta(MetaEvent)`,
      `case error(ErrorEvent)`, `case completion(CompletionEvent)` (unlabeled, matching
      `Result.success`/`.failure` convention). Update all switch/pattern-match call sites
      across PositronicKit and downstream consumers.
- [ ] Move blocked-error classification onto `PKError` itself (e.g. a `var isBlocked: Bool`
      or similar on the error types in `PKErrorDomain.tool`/`.filesystem`/`.workspace`
      that actually represent blocked conditions) and have `ErrorIdentity.blocked`/
      `isBlocked` derive from that rather than hand-listing codes. If that's too large a
      refactor for this ticket, at minimum add a test that fails if a new blocked-style
      error is added without updating the set (a compile-time or runtime tripwire),
      documented inline for why the set exists.

### Acceptance Criteria

- [ ] No case-name collision between `.failed`/`.failure` variants across
      `ToolExecutionStatus`/`ToolResult`.
- [ ] `ChatEvent` category cases are unlabeled; call sites updated.
- [ ] Blocked-error classification either lives on `PKError` or has an explicit tripwire
      test preventing silent drift.
- [ ] Downstream grep across Monad/Shuttle/Yakamoz for `ChatEvent` pattern-matching and
      `ToolExecutionStatus`/`ToolResult` usage.
- [ ] `make verify` green; CHANGELOG updated (breaking).
