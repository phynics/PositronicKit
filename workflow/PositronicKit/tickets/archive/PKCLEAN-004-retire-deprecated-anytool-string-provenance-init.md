# PKCLEAN-004 — Retire the deprecated AnyTool string-provenance initializer

**Priority:** P3
**Type:** API migration (public API change)
**Depends on:** —
**Blocks:** —
**Triage:** ready-for-agent
**Status:** Done (2026-07-09, commit `c937186`) — deleted the deprecated
`AnyTool.init(_ tool:provenance: String?)` and its two tests. Zero downstream callers across
Monad/Shuttle/Yakamoz (both Yakamoz sites already use the `ToolProvenance` overload). Breaking
public API removal, source-compatible in practice for released-pin consumers. `swift test` green
(923 tests / 158 suites, -2 removed deprecated tests).

### Triage Notes (2026-07-09)

Downstream grep for `AnyTool(` + `provenance:` across Monad/Shuttle/Yakamoz found two call
sites (`Yakamoz/Sources/YakamozCore/Tools/ReadOnlyToolApproval.swift:36`,
`Yakamoz/Sources/YakamozCore/Tools/ToolExplanationParameter.swift:14`), but both pass
`provenance: provenance` where `provenance` is `AnyTool.provenance: ToolProvenance`
(`Tool.swift:215`) — i.e. they resolve to the current, non-deprecated
`init(_:provenance: ToolProvenance = .global)` overload, not the deprecated `String?` one.
Zero real downstream callers of the deprecated initializer. Ready to implement per the
ticket's existing Implementation Requirements.

### Summary

`AnyTool.init(_ tool:provenance: String?)` is marked `@available(*, deprecated, renamed:
"init(_:provenance:)")` (the new init takes `ToolProvenance`). The only in-repo caller is a
test that exercises the deprecated path. Confirm no downstream consumer (Monad, Shuttle,
Yakamoz) still uses the string-form `provenance:` initializer, then delete it.

### Current Problem

- `Sources/PKShared/Tools/Tool.swift:222`:
  ```swift
  @available(*, deprecated, renamed: "init(_:provenance:)")
  public init(_ tool: any Tool, provenance: String?) {
      self.init(tool, provenance: provenance.map { .named($0) } ?? .global)
  }
  ```
- The only in-repo caller is `Tests/PKSharedTests/Tools/ToolProvenanceTests.swift:54`
  (`AnyTool(tool, provenance: "Legacy")`) — a test that exists solely to cover the deprecated
  path.
- The replacement `init(_ tool:provenance: ToolProvenance = .global)` (line 217) covers all
  cases (`String?` → `.named($0) ?? .global`).

### Implementation Requirements

1. Grep **all three consumers** (Monad, Shuttle, Yakamoz) for `AnyTool(` with a string-form
   `provenance:` argument (downstream-sync checklist — root `CLAUDE.md`).
2. If any downstream caller remains, migrate it to `provenance: .named("...")` / `.global`
   first (coordinate via the local-path override while unreleased).
3. Delete the deprecated initializer (`Tool.swift:222-225`).
4. Delete or update `ToolProvenanceTests.swift:54` so it no longer exercises the removed init.
5. Update `CHANGELOG.md` under `Unreleased` → `Removed` (or `Breaking` if any downstream caller
   existed) and follow `docs/Releasing.md` for the tag/pin workflow.

### Acceptance Criteria

- [ ] Downstream grep results recorded in the ticket (zero callers, or all migrated).
- [ ] Deprecated `init(_ tool:provenance: String?)` deleted from `Tool.swift`.
- [ ] `ToolProvenanceTests` no longer references the removed init.
- [ ] `swift build` + `swift test` green (880 tests / 155 suites baseline, minus the removed
      deprecated-init test case).
- [ ] `CHANGELOG.md` `Unreleased` updated.
- [ ] Downstream-sync checklist run (grep Monad, Shuttle, Yakamoz).
