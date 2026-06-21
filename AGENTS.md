# AGENTS

`PositronicKit` — Swift package for agent runtime and prompt composition.

## Layout

- `Package.swift` — package manifest.
- `Sources/PositronicKit` — runtime: orchestration stages, chat engine, tool routing, timelines, workspaces, LLM services.
- `Sources/PKPrompt` — prompt composition: `PromptBuilder` DSL, `PromptNode` IR, assembly, compression, `PromptJournal`.
- `Sources/PKShared` — shared contracts: API models, tool protocols, error types, logging, utilities.
- `Sources/PKOpenAIProvider`, `Sources/PKOpenRouterProvider`, `Sources/PKOllamaProvider` — concrete provider adapters and provider-specific convenience APIs.
- `Sources/PositronicKitExamples` — runnable examples; double as living documentation.
- `Tests/PKTestSupport` — mocks, fixtures, test helpers (library product).
- `Tests/PositronicKitTests`, `Tests/PKPromptTests`, `Tests/PKSharedTests` — per-module test targets.

## Commands

```
swift build                        # or: make build
swift test                         # or: make test
swift run PositronicKitExamples
make clean
make verify                       # pin, docs, linkage, and test gates
make verify-products              # build every product on this host
make verify-pin                   # check the pinned MiniLM artifact hashes are consistent
make build-minilm                 # prepare assets/bridge and build the MiniLM trait product
make verify-minilm                # prepare native MiniLM and run its tests
```

`build-minilm` and `verify-minilm` both depend on `bootstrap-minilm`, which is
idempotent: it downloads the pinned model assets on first use, verifies their
checksums, and builds PKFastEmbed only when missing — so the MiniLM build/test
pipeline prepares everything without a separate manual bootstrap step. Assets and
the native prefix are stored under `.build` (gitignored) by default; override
`PKFASTEMBED_PREFIX` and `PK_MINILM_MODEL_DIR` to relocate the cache. The pinned
revision and per-file SHA-256 hashes live in `Packages/PKFastEmbed/model-assets.sha256`
and `Sources/PKLocalEmbeddings/MiniLMModelAssets.swift`; `verify-pin` (run by
`verify` and before every bootstrap) fails if those drift apart.

## Module Boundaries

| Module | Owns | Does Not Own |
|--------|------|--------------|
| `PKShared` | API models, tool contracts, logging, utilities | Prompt logic, orchestration, persistence |
| `PKPrompt` | Prompt IR, assembly, rendering, compression, journaling | Runtime, persistence, transport |
| `PositronicKit` | Orchestration, chat lifecycle, tool routing, timeline/workspace mgmt | Concrete provider SDK integrations, transport, RPC, hosting, prompt-tree internals |
| `PKOpenAIProvider` / `PKOpenRouterProvider` / `PKOllamaProvider` | Concrete provider clients, provider-specific conversions, convenience registration/init APIs | Runtime orchestration, prompt-tree internals |

## Conventions

- Swift 6 concurrency: `Sendable`, actor isolation, no shared mutable state.
- Composition over inheritance. Narrow protocols. Explicit `throws`.
- Structured logging via `PKShared`.
- Error handling uses `ErrorKit` through `PKShared.PKError`: package-defined errors should conform to `PKError`, use `PKErrorDomain`, provide stable `errorCode` values, and implement `userFriendlyMessage` (plus `remediation` when the caller has a concrete recovery step).
- When surfacing nested errors to users, tools, or higher-level logs, prefer `ErrorKit.userFriendlyMessage(for:)`; reserve `localizedDescription` for low-level diagnostics.
- Tests accompany every behavioral change; use `PKTestSupport` helpers.
- Keep `PositronicKitExamples` compiling and current with public APIs.
- Prefer `JSONSchema`/`JSONSchemaBuilder`; derive from `@Schemable` when schema mirrors a Swift model.
- Do not introduce custom schema wrapper types when `JSONSchema`, `Schema`, `JSONSchemaBuilder`, or `@Schemable` already cover the use case.
- Fixtures: deterministic, lightweight; prefer reusable builders over inline setup.
- `swift build && swift test` before opening or updating PRs.

## PositronicKit Invariants

- Transport-neutral. Concrete networking, RPC, and hosting belong downstream.
- Concrete provider implementations are downstream from `PositronicKit`: keep provider SDK adapters in dedicated provider targets, not in the core runtime target.
- Downstream pluggability is non-negotiable: persistence, workspace resolution, tool execution, prompting, and UI/network layers are all injectable.
- Consume `PKPrompt` artifacts (`AssembledPrompt`, `RenderedPrompt`). Never reimplement prompt-tree semantics.
- Extension points: persistence protocols, `WorkspaceCreating`/`WorkspaceProtocol`, `PromptSectionProviding`, `ToolRouter`, `ChatTurnPlugin`.
- Core types: `Timeline`, `AgentInstance`, `ChatEngine`, `TimelineManager`, `ToolRouter`, `WorkspaceManager`.

## PKPrompt Invariants

- `PromptNode` = canonical internal IR. `PromptBuilder` first composes structural `Prompt` values; `PromptAssembly` lowers them to nodes.
- `AssembledPrompt` = validated section artifact. `RenderedPrompt` = canonical render output.
- `PromptJournal` = prompt-history primitive. Cache policies determine lifecycle: stable → materialized base, semi-stable → overlays until `compact()`, volatile → current-only, stable mutations → hard reset.
- Author prompts via `var body: some Prompt`, composing `SystemPrompt`, `TextPrompt`, `UserPrompt`, `HistoryPrompt`, and custom `Prompt` types.
- Trait modifiers (`.priority(...)`, `.compression(...)`, `.cachePolicy(...)`) inherit through subtree; resolved once at assembly.
- Three consumption layers: `Prompt → String` | `Prompt → AssembledPrompt → RenderedPrompt` | `RenderedPrompt → PromptJournal`.
