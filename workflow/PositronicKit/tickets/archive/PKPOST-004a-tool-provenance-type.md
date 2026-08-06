# PKPOST-004a: Structural `ToolProvenance` on `AnyTool` (replaces the display string)

**Priority:** P3
**Type:** Refactor (public API — ships in the next minor with a deprecated bridge)
**Depends on:** PKPOST-004 spec (`workflow/PositronicKit/specs/2026-07-05-workspace-scoped-tools.md`, decision D2)
**Blocks:** PKPOST-004b, PKPOST-004c
**Triage:** ready-for-human
**Status:** Done (2026-07-06)

**Resolution:** Implemented in PositronicKit `72ec444`: `ToolProvenance` enum,
`AnyTool.provenance` migration, deprecated string-init bridge, prompt-label parity
and wrap-preserves-provenance tests. Downstream consumers compile and pass gates
against `1.1.0`.

## Summary

Replace `AnyTool.provenance: String?` (`Sources/PKShared/Tools/Tool.swift:174`) with the
structural enum from spec D2 (`case global / workspace(id:name:) / terminal(id:name:)`),
defaulting to `.global`. Keep a deprecated string-init bridge for one release. Prompt
rendering (`Tool.promptString(provenance:)`, `Tool.swift:104,120`) renders the enum's `name`
— assert byte-identical prompt output for the existing workspace-labeled case.

## Acceptance Criteria

- [ ] `ToolProvenance` enum public in PKShared; `AnyTool.provenance` migrated; deprecated
      string bridge in place.
- [ ] Prompt-label parity test (before/after identical rendered tool spec).
- [ ] Existing decorators (`withExplanationParameter()` in Yakamoz — verify via downstream
      grep only; PK-side `AnyTool` wrapping paths) forward provenance; test in PK for the
      wrap-preserves-provenance invariant.
- [ ] Downstream grep (Monad/Shuttle/Yakamoz) for `provenance` string usage; `make verify`
      + `make verify-products` green.
