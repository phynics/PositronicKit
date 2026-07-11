# AGENTS

`PositronicKit` — Swift package for agent runtime and prompt composition.

## Layout

- `Package.swift` — package manifest.
- `Sources/PositronicKit` — runtime: orchestration stages, chat engine, tool routing, timelines, workspaces, LLM services.
- `Sources/PKPrompt` — prompt composition: `PromptBuilder` DSL, `PromptNode` IR, assembly, compression, `PromptJournal`.
- `Sources/PKShared` — shared contracts: API models, tool protocols, error types, logging, utilities.
- `Sources/PKLocalEmbeddings` — platform-local embedding facade (`LocalEmbeddingService`); Natural Language on Apple by default, host-provisioned MiniLM on Linux.
- `Sources/PKFastEmbed` / `Sources/CPKFastEmbed` — Rust bridge (via `fastembed`) and its Clang system-library wrapper for the in-process MiniLM backend (Linux default; Apple opt-in via the `MiniLMEmbeddings` trait).
- `Sources/PKOpenAIProvider`, `Sources/PKOpenRouterProvider`, `Sources/PKOllamaProvider`, `Sources/PKAnthropicProvider`, `Sources/PKFoundationModelsProvider` — concrete provider adapters and provider-specific convenience APIs.
- `Sources/PKObservable` — opt-in `@Observable` wrappers (`ObservableConversation`) for SwiftUI-facing consumers.
- `Sources/PositronicKitExamples` — runnable examples; double as living documentation.
- `Tests/PKTestSupport` — mocks, fixtures, test helpers (library product).
- `Tests/PositronicKitTests`, `Tests/PKPromptTests`, `Tests/PKSharedTests`, `Tests/PKLocalEmbeddingsTests`, `Tests/PKFastEmbedTests`, `Tests/PKObservableTests`, `Tests/PKTestSupportTests` — per-module test targets.

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
make verify-linux-minimum         # run the minimum Linux matrix gate (Swift 6.1.3 on Ubuntu 24.04)
make verify-linux-current         # run the current Linux matrix gate (Swift 6.3.2 on Ubuntu 24.04)
make verify-linux-asan            # run the PKFastEmbed bridge tests under Linux x86_64 AddressSanitizer
make verify-macos-default         # run the default macOS gate
make verify-macos-minilm          # run the MiniLM macOS gate
```

See [docs/Releasing.md](docs/Releasing.md) for the release workflow, tagging steps, and
consumer upgrade cadence.

`build-minilm` and `verify-minilm` both depend on `bootstrap-minilm`, which is
idempotent: it downloads the pinned model assets on first use, verifies their
checksums, and builds PKFastEmbed only when missing — so the MiniLM build/test
pipeline prepares everything without a separate manual bootstrap step. Assets and
the native prefix are stored under `.build` (gitignored) by default; override
`PKFASTEMBED_PREFIX` and `MINILM_MODEL_CACHE_ROOT` to relocate the cache. The
Makefile keys the default MiniLM cache directory by the pinned `model.onnx`
SHA-256 so stale assets cannot be reused. The pinned revision and per-file
SHA-256 hashes live in `native/pkfastembed/model-assets.sha256` and
`Sources/PKLocalEmbeddings/MiniLMModelAssets.swift`; `verify-pin` (run by
`verify` and before every bootstrap) fails if those drift apart.

## Linux Development Setup

`PositronicKit`, `PKPrompt`, and `PKShared` build with a bare Swift 6.1+ toolchain (no
extra system packages). Building or testing `PKLocalEmbeddings`/`PKFastEmbed` — the
default on Linux, opt-in on Apple via the `MiniLMEmbeddings` trait — additionally
requires:

| Dependency | Why |
|------------|-----|
| Swift 6.1+ toolchain | Package manifest tools-version; [swiftly](https://swift.org/install) is the easiest install path. |
| Rust toolchain (`cargo`, stable) | `native/pkfastembed/bootstrap.sh` runs `cargo build --release --locked` to produce `libpkfastembed.a`. |
| C/C++ toolchain (`gcc`/`g++` or `clang`) | Links `libstdc++`; also needed by Rust's `cc` crate for native build scripts. |
| `pkg-config` | `CPKFastEmbed` is declared as a SwiftPM `systemLibrary` with `pkgConfig: "pkfastembed"`; the Makefile also passes `PKG_CONFIG_PATH` directly to `swift build`/`swift test`. |
| OpenSSL development headers (`libssl-dev` on Debian/Ubuntu, `openssl-devel` on Fedora/RHEL) | `fastembed`'s `ort-download-binaries-native-tls` feature depends on `native-tls` → `openssl-sys`, which links system OpenSSL (not vendored). |
| `curl` | `Scripts/bootstrap-minilm-ci.sh` downloads the pinned Hugging Face model assets. |
| `shasum` (Perl `Digest::SHA`, not just coreutils `sha256sum`) | `bootstrap-minilm-ci.sh` calls `shasum -a 256 --check` against `native/pkfastembed/model-assets.sha256`. |
| Network access during first bootstrap | Cargo fetches crates.io dependencies and the ONNX Runtime binary; the model-asset download hits Hugging Face directly. |

**Known SwiftPM/Linux linking gap:** `systemLibrary` + `pkgConfig` only wires the
`-I` (cflags) into the compile step on Linux — it does not propagate pkg-config's
`Libs:` (`-L` search path) to the final link step. `-lpkfastembed` reaches the
linker via Clang autolinking (`Sources/CPKFastEmbed/module.modulemap`'s `link`
directive), so without an explicit `-L` the linker can't resolve it. The
`PKFastEmbed` target's `linkerSettings` in `Package.swift` works around this by
adding `-L<PKFASTEMBED_PREFIX>/lib` directly (`PKFASTEMBED_PREFIX` defaults to
`.build/pkfastembed` and is exported by the Makefile).

Once those are installed, the canonical Linux gate is:

```bash
make verify-linux-current   # bootstrap-minilm, then default `swift test` + `swift test --traits MiniLMEmbeddings`
```

`verify-linux-current` intentionally does **not** depend on `validate-docs` (unlike `verify`,
the Apple gate) — DocC and `swift-symbolgraph-extract` are resolved from an Xcode
toolchain path in `Scripts/validate-docc.sh` and don't exist on Linux. The story
tests `validate-docs` also runs are a subset already covered by `verify-linux-current`'s
full `swift test` step, so no coverage is lost.
`verify-linux-minimum` is the same gate, reserved for the Swift 6.1.3 / Ubuntu 24.04
matrix job.

For the bridge-only AddressSanitizer qualification gate used by `PKFAST-006`, run:

```bash
rustup toolchain install nightly
rustup component add rust-src --toolchain nightly
make verify-linux-asan
```

`verify-linux-asan` scopes to `native/pkfastembed` only; it does not run the full
Swift MiniLM matrix. Override `PKFASTEMBED_ASAN_TOOLCHAIN` or
`PKFASTEMBED_ASAN_TARGET` when the host differs from the default nightly
`x86_64-unknown-linux-gnu` setup.

## Module Boundaries

| Module | Owns | Does Not Own |
|--------|------|--------------|
| `PKShared` | API models, tool contracts, logging, utilities | Prompt logic, orchestration, persistence |
| `PKPrompt` | Prompt IR, assembly, rendering, compression, journaling | Runtime, persistence, transport |
| `PositronicKit` | Orchestration, chat lifecycle, tool routing, timeline/workspace mgmt | Concrete provider SDK integrations, transport, RPC, hosting, prompt-tree internals |
| `PKOpenAIProvider` / `PKOpenRouterProvider` / `PKOllamaProvider` / `PKAnthropicProvider` / `PKFoundationModelsProvider` | Concrete provider clients, provider-specific conversions, convenience registration/init APIs | Runtime orchestration, prompt-tree internals |

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
- For public API changes, update `CHANGELOG.md` under `Unreleased` and follow
  `docs/Releasing.md` for the tag/pin workflow instead of treating `main` as the consumer
  source of truth.

## PositronicKit Invariants

- Transport-neutral. Concrete networking, RPC, and hosting belong downstream.
- Concrete provider implementations are downstream from `PositronicKit`: keep provider SDK adapters in dedicated provider targets, not in the core runtime target.
- Downstream pluggability is non-negotiable: persistence, workspace resolution, tool execution, prompting, and UI/network layers are all injectable.
- Consume `PKPrompt` artifacts (`AssembledPrompt`, `RenderedPrompt`). Never reimplement prompt-tree semantics.
- Extension points: persistence protocols, `WorkspaceCreating`/`WorkspaceProtocol`, `PromptSectionProviding`, `ToolRouter`, `ChatTurnPlugin`.
- Primary entry point: the `PositronicKit` facade (a `final class` config owner). Choose the smallest operation tier: one-shot `complete(_:)`/`stream(_:)`, `Conversation` cursors, `timelineManager` + `run(...)`, `agenticRuntime(...)`, or raw public seams (`TimelineManager`, `ToolRouter`, persistence/workspace protocols).
- Core public types: `Timeline`, `AgentInstance`, `TimelineManager`, `ToolRouter`, `WorkspaceManager`. `ChatEngine` and the turn pipeline are internal implementation details (driven through the facade).

## PKPrompt Invariants

- `PromptNode` = canonical internal IR. `PromptBuilder` first composes structural `Prompt` values; `PromptAssembly` lowers them to nodes.
- `AssembledPrompt` = validated section artifact. `RenderedPrompt` = canonical render output.
- `PromptJournal` = prompt-history primitive. Cache policies determine lifecycle: stable → materialized base, semi-stable → overlays until `compact()`, volatile → current-only, stable mutations → hard reset.
- Author prompts via `var body: some Prompt`, composing `SystemPrompt`, `TextPrompt`, `UserPrompt`, `HistoryPrompt`, and custom `Prompt` types.
- Trait modifiers (`.priority(...)`, `.compression(...)`, `.cachePolicy(...)`) inherit through subtree; resolved once at assembly.
- Three consumption layers: `Prompt → String` | `Prompt → AssembledPrompt → RenderedPrompt` | `RenderedPrompt → PromptJournal`.

## Workflow Artifacts

This repo holds **reference docs only** (`docs/`, `README.md`).
Agentic-workflow scaffolding (superpowers specs/plans, decomposed tickets, brainstorm output)
lives centrally at the workspace root under `workflow/`, namespaced by project:

```text
../workflow/
  PositronicKit/plans/ specs/ tickets/   # this project's artifacts
  Monad/plans/
  Shuttle/plans/ specs/
  Yakamoz/plans/ specs/ checkpoints/ tickets/ brainstorm/
  workspace/plans/                       # cross-cutting workspace plans
```

Put new specs/plans/tickets under `../workflow/PositronicKit/...`, **not** back inside `docs/`.
See the root `../CLAUDE.md` for the full layout.

Tickets follow the workspace ticketing system (root `../CLAUDE.md`, "Ticketing system"):
one `<SERIES>-<id>-<slug>.md` file per ticket with a `Status` line (new tickets also carry a
`Triage:` line — see root `../CLAUDE.md`, "Triage labels"); the index is
`../workflow/PositronicKit/tickets/README.md` and is updated in the same change as any
status flip; `Done`/`Discarded` tickets move to `tickets/archive/`.

### Downstream consumer compatibility

Since v1.0, PositronicKit follows semver and downstream consumers pin to released
versions. You do **not** need to build or test Monad, Shuttle, or Yakamoz as part of every
PositronicKit change. Consumer build/test gates are run later, against the tagged
PositronicKit release, following [`docs/Releasing.md`](docs/Releasing.md). Use the
documented local-path override only when a specific consumer change is being developed
in tandem with an unreleased PositronicKit API.
