# PKPOST-004b: Remove `workspaceID` schema parameters from the filesystem tools

**Priority:** P3
**Type:** Refactor (tool schema change — ships in the next minor)
**Depends on:** PKPOST-004a
**Blocks:** PKPOST-004c
**Triage:** ready-for-human
**Status:** Done (2026-07-06)

**Resolution:** Implemented in PositronicKit `72ec444`: `workspaceID` properties
removed from all five filesystem tools, prompt guidance updated, and regression tests
verify stray `workspaceID` arguments are ignored. `make verify` green.

## Summary

Workspace tools are already constructed bound to their workspace root; the model-echoed
`workspaceID` argument is routing noise and a misroute risk (spec D3). Delete the
`workspaceID` `JSONProperty` and its extraction from all five filesystem tools
(`Sources/PKShared/Tools/Filesystem/`: `ReadFileTool.swift:40`, `ListDirectoryTool.swift:39`,
`FindFileTool.swift:43`, `SearchFilesTool.swift:58`, `SearchFileContentTool.swift:58`) and
rewrite the prompt path-resolution guidance (`Tool.swift:131`) to drop the id-echo
instruction.

## Acceptance Criteria

- [ ] No `workspaceID` in any filesystem tool schema or `execute` extraction; tools execute
      against their bound root.
- [ ] Prompt guidance no longer instructs the model to pass workspace ids.
- [ ] Regression test: a call with a stray `workspaceID` argument still executes (ignored,
      pass-through tolerant) — persisted historical arguments remain readable.
- [ ] Downstream grep for `workspaceID` argument reliance (none expected — Yakamoz
      transcript rendering treats arguments as opaque); `make verify` green.
