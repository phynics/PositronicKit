# PKARCH-006: Unbundle InMemoryStores

**Priority:** P3
**Type:** Internal refactor (no public API change)
**Depends on:** None
**Blocks:** None
**Status:** Done (commit `4a14f88` in `pkarch-006-unbundle-inmemorystores`)
**Triage:** ready-for-agent

### Summary

`Sources/PositronicKit/Services/Storage/InMemoryStores.swift` implements seven unrelated persistence actors in one 379-line file. The corresponding protocols each live in their own small file, so the cohesion is inverted: implementations are bundled while interfaces are split. This ticket unbundles the file so each actor lives in its own file named after its protocol.

### Current Problem

- Finding a specific store requires scrolling through unrelated actors.
- Changing one store's implementation forces a diff in a file that also owns six other stores.
- The deletion test fails for the bundle: deleting the file removes seven adapters at once, but the complexity of each adapter is independent.

### Implementation Requirements

1. Create one file per in-memory adapter under `Sources/PositronicKit/Services/Storage/`:
   - `InMemoryMessageStore.swift`
   - `InMemoryTimelinePersistence.swift`
   - `InMemoryWorkspacePersistence.swift`
   - `InMemoryMemoryStore.swift`
   - `InMemoryToolPersistence.swift`
   - `InMemoryAgentInstanceStore.swift`
   - `InMemoryRequestOriginStore.swift`
   - `InMemoryAgentTemplateStore.swift`
2. Move each actor and its doc comment into its own file; keep the package/internal access levels unchanged.
3. Delete `InMemoryStores.swift` once the move is complete.
4. Update any imports or file references that explicitly pointed to `InMemoryStores` (SwiftPM compiles by target, so this should not be needed).

### Resolution

Split `Sources/PositronicKit/Services/Storage/InMemoryStores.swift` into eight per-actor files (`InMemoryMessageStore.swift`, `InMemoryTimelinePersistence.swift`, `InMemoryWorkspacePersistence.swift`, `InMemoryMemoryStore.swift`, `InMemoryToolPersistence.swift`, `InMemoryAgentInstanceStore.swift`, `InMemoryRequestOriginStore.swift`, `InMemoryAgentTemplateStore.swift`) and deleted the original bundle. Access levels and behavior preserved exactly. `make verify` green (851 tests / 154 suites). No public API change; no CHANGELOG entry needed.

### Acceptance Criteria

- [x] `InMemoryStores.swift` is removed.
- [x] Each in-memory actor exists in its own file with the same public/package API as before.
- [x] All existing tests compile and pass without modification.
- [x] `make verify` green.
- [x] No behavioral changes; this is a pure structural refactor.
