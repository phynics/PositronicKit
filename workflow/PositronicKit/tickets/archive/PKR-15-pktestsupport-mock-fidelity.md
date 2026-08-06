# PKR-15 — PKTestSupport mock fidelity gaps: `listFiles` scope divergence, incomplete `resetDatabase`

**Status:** Done
**Severity:** 🟡 Low (tests can't observe production behavior)
**Repos:** PositronicKit (PKTestSupport) + Monad (contract decision)
**Source:** PositronicKit review 2026-07-02

## Problem

1. **`MockLocalWorkspace.listFiles` scoping** (`Tests/PKTestSupport/MockLocalWorkspace.swift:48-65`):
   the mock enumerates from the requested `path` (path-scoped), while the real
   `LocalWorkspace.listFiles` (`Monad/Sources/MonadServer/Models/Workspace/LocalWorkspace.swift:54-58`)
   validates `path` but then always enumerates from the root — i.e. production ignores `path` for
   scoping (arguably its own oddity). Tests written against the mock's scoped behavior don't
   reproduce production. Decide the intended contract and align both.
2. **`MockPersistenceService.resetDatabase()`** (`Tests/PKTestSupport/MockPersistenceService.swift:288-295`)
   resets memories/messages/timelines/templates/workspaces but not `agentInstances` (`:262`) or the
   internal `toolsMock` workspace list mutated by `saveWorkspace`/`fetchWorkspace` (`:184-201`) —
   stale state leaks across "clean slate" test boundaries.

## Suggested direction

Pick the `listFiles` contract (path-scoped seems intended), fix whichever side is wrong, and add a
shared contract test. Complete `resetDatabase()` to clear agent instances and tool associations.

## Resolution (2026-07-04)

**Contract decision:** path-scoped enumeration is correct — confirmed by tracing
`NoteDiscoveryStage`, which calls `listFiles(path: "Notes")` and feeds the result straight into
`readFile(path:)` (root-relative). Production (`Monad/Sources/MonadServer/Models/Workspace/LocalWorkspace.swift`)
was the bug: it validated `path` but always enumerated from the workspace root. Fixed production to
enumerate from the resolved target directory; returned path strings stay root-relative (unchanged),
since callers reuse them directly against `readFile`/`writeFile`. `MockLocalWorkspace` was already
correct. Added a parallel contract test in both repos asserting the same input/output behavior.

`MockPersistenceService.resetDatabase()` now also clears `agentInstances` and the internal
`toolsMock` workspace list, matching the other cleared collections.

PositronicKit: `swift test --filter PKTestSupport` green. Monad: `swift build`/full `swift test`
green (one pre-existing unrelated failure, `ServerLLMServiceTests."Test generateTitle"`, confirmed
present on the parent commit too — not caused by this change).
