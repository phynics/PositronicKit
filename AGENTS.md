# AGENTS

`PositronicKit` — Swift package for agent runtime and prompt composition.

## Layout

- `Package.swift` — manifest.
- `Sources/PositronicKit` — runtime: orchestration, chat engine, tool routing, timelines, workspaces, LLM services.
- `Sources/PKPrompt` — prompt composition DSL + IR (`PromptBuilder`, `PromptNode`, `PromptJournal`).
- `Sources/PKShared` — shared contracts: API models, tool protocols, errors, logging, utilities.
- `Sources/PKUtilities` — cross-cutting helpers used by runtime + providers.
- `Sources/PKLocalEmbeddings` — platform-local embedding facade; Natural Language on Apple, MiniLM on Linux.
- `Sources/PKFastEmbed` + `Sources/CPKFastEmbed` — Rust bridge (via `fastembed`) + Clang wrapper for in-process MiniLM backend (Linux default; Apple opt-in via `MiniLMEmbeddings`).
- `Sources/PKOpenAIProvider` / `PKOpenRouterProvider` / `PKOllamaProvider` / `PKAnthropicProvider` / `PKFoundationModelsProvider` — provider adapters + provider-specific convenience APIs.
- `Sources/PKObservable` — opt-in `@Observable` wrappers for SwiftUI consumers.
- `Sources/PositronicKitExamples` — runnable examples, live docs.
- `Tests/PKTestSupport` — mocks, fixtures, test helpers (library product).
- `Tests/PositronicKitTests`, `Tests/PKPromptTests`, `Tests/PKSharedTests`, `Tests/PKUtilitiesTests`, `Tests/PKLocalEmbeddingsTests`, `Tests/PKFastEmbedTests`, `Tests/PKObservableTests`, `Tests/PKOpenAIProviderTests`, `Tests/PKOpenRouterProviderTests`, `Tests/PKOllamaProviderTests`, `Tests/PKAnthropicProviderTests`, `Tests/PKFoundationModelsProviderTests`, `Tests/PKTestSupportTests` — per-module test targets.

## Commands

```
swift build                        # or: make build
swift test                         # or: make test
swift run PositronicKitExamples
make verify                        # macOS full gate: pin, docs, linkage, products, examples, tests
make verify-linux-current          # full Linux gate (Swift 6.3.3 / Ubuntu 24.04)
make build-minilm                  # bootstrap assets + build MiniLM trait product
make verify-minilm                 # bootstrap + run MiniLM gates
make doctor                        # report missing prereqs (Swift, Rust, container runtime, ...)
```

`make verify-linux-asan` runs PKFastEmbed bridge tests under Linux x86_64
AddressSanitizer (needs nightly rustup toolchain + rust-src). Linux container targets
then live in [Linux Development Setup](#linux-development-setup) below. `make help`
lists all targets.

See [docs/Releasing.md](docs/Releasing.md) for release workflow, tagging steps, and
consumer upgrade cadence.

`build-minilm` + `verify-minilm` depend on `bootstrap-minilm`, idempotent: download
pinned model assets on first use, verify checksums, build PKFastEmbed only when missing —
no separate manual bootstrap. Assets + native prefix stored under `.build` (gitignored)
by default; override `PKFASTEMBED_PREFIX` / `MINILM_MODEL_CACHE_ROOT` to relocate. Makefile
keys default MiniLM cache by pinned `model.onnx` SHA-256, so stale assets unusable. Pinned
revision + per-file SHA-256 live in `native/pkfastembed/model-assets.sha256` and
`Sources/PKLocalEmbeddings/MiniLMModelAssets.swift`; `verify-pin` (run by `verify` and
before every bootstrap) fails if they drift.

## Development Setup

### macOS (native)

Prefer native Swift/Xcode on macOS — no container needed for normal work. Gate:
`make verify` (pin, docs, linkage, products, examples, tests) or
`make verify-macos-minilm` when exercising the native MiniLM trait. MiniLM is opt-in on
Apple via the `MiniLMEmbeddings` trait (uses Natural Language by default).

### Linux (container)

Container-based development is for **Linux** — use native Swift on macOS instead. Dev
Container (`.devcontainer/`) provides Swift 6.3.3, Rust stable, all native prerequisites
on Ubuntu 24.04. From repo root:

```bash
make linux-image   # Build the development image
make linux-build   # build-minilm in container (bind-mounted)
make linux-test    # full Linux gate in container (make verify-linux-current)
```

Runtime auto-detected: `podman` preferred, else `docker`. Override
`CONTAINER_RUNTIME=/path/to/runtime`; image tag via `LINUX_IMAGE` (default
`positronickit-linux-dev`). No runtime on PATH — targets fail fast; `make doctor`
reports missing prereqs.

Containers run rootless (podman `--userns=keep-id`, docker `--user $(id -u):$(id -g)`)
with `HOME=/tmp`, `CARGO_HOME=/tmp/cargo`. Checkout bind-mounted at `/workspace`
(SELinux `:Z` label), so host edits visible immediately; build artifacts land in host
`.build/` (gitignored). `linux-build` runs `make build-minilm`; `linux-test` runs
`make verify-linux-current`.

VS Code Dev Containers extension for full IDE experience.

### Linux (bare toolchain)

`PositronicKit`, `PKPrompt`, `PKShared` build with bare Swift 6.1+ toolchain (no extra
system packages). Building/testing `PKLocalEmbeddings`/`PKFastEmbed` — default on Linux,
opt-in on Apple via `MiniLMEmbeddings` trait — additionally requires:

| Dependency | Why |
| ------------ | ----- |
| Swift 6.1+ toolchain | Package manifest tools-version; [swiftly](https://swift.org/install) is the easiest install path. |
| Rust toolchain (`cargo`, stable) | `native/pkfastembed/bootstrap.sh` runs `cargo build --release --locked` to produce `libpkfastembed.a`. |
| C/C++ toolchain (`gcc`/`g++` or `clang`) | Links `libstdc++`; also needed by Rust's `cc` crate for native build scripts. |
| `pkg-config` | `CPKFastEmbed` is declared as a SwiftPM `systemLibrary` with `pkgConfig: "pkfastembed"`; the Makefile also passes `PKG_CONFIG_PATH` directly to `swift build`/`swift test`. |
| OpenSSL dev headers | `fastembed`'s `native-tls` feature links system OpenSSL. |
| `curl` | `Scripts/bootstrap-minilm-ci.sh` downloads the pinned Hugging Face model assets. |
| `shasum` (Perl `Digest::SHA`) | `bootstrap-minilm-ci.sh` calls `shasum -a 256 --check` against `native/pkfastembed/model-assets.sha256`. |
| Network access during first bootstrap | Cargo fetches crates.io deps + ONNX Runtime binary; model assets from Hugging Face. |

**Known SwiftPM/Linux linking gap:** `systemLibrary` + `pkgConfig` wires only `-I`
(cflags) into compile, not pkg-config's `Libs:` (`-L` search path). `-lpkfastembed` reaches
linker via Clang autolinking (`Sources/CPKFastEmbed/module.modulemap`'s `link` directive),
so without explicit `-L` linker can't resolve. `PKFastEmbed`'s `linkerSettings` in
`Package.swift` adds `-L<PKFASTEMBED_PREFIX>/lib` directly (`PKFASTEMBED_PREFIX` defaults
to `.build/pkfastembed`, exported by Makefile).

Canonical Linux gate:

```bash
make verify-linux-current   # bootstrap-minilm, then `swift test` + `swift test --traits MiniLMEmbeddings`
```

`verify-linux-current` skips `validate-docs` (unlike `verify` on Apple) — DocC +
`swift-symbolgraph-extract` resolved from Xcode toolchain path in `Scripts/validate-docc.sh`,
absent on Linux. Story tests `validate-docs` runs are subset of its full `swift test`, so
no coverage lost.

Bridge-only AddressSanitizer gate for `PKFAST-006`:

```bash
rustup toolchain install nightly
rustup component add rust-src --toolchain nightly
make verify-linux-asan
```

`verify-linux-asan` scopes to `native/pkfastembed` only. Override
`PKFASTEMBED_ASAN_TOOLCHAIN` / `PKFASTEMBED_ASAN_TARGET` when host differs from default
`x86_64-unknown-linux-gnu` nightly setup.

## Module Boundaries

| Module | Owns | Does Not Own |
| -------- | ------ | -------------- |
| `PKShared` | API models, tool contracts, errors, logging, utilities | Prompt logic, orchestration, persistence |
| `PKUtilities` | Cross-cutting helpers (crypto, docs, utils) reused by runtime + providers | Prompt IR, orchestration, transport |
| `PKPrompt` | Prompt IR, assembly, rendering, compression, journaling | Runtime, persistence, transport |
| `PositronicKit` | Orchestration, chat lifecycle, tool routing, timeline/workspace mgmt | Concrete provider SDK integrations, transport, RPC, hosting, prompt-tree internals |
| `PKObservable` | `@Observable` wrappers for SwiftUI consumers | Runtime orchestration, transport, persistence |
| `PKLocalEmbeddings` | Platform-local embedding facade (Natural Language / MiniLM) | Runtime orchestration, prompt-tree internals, transport |
| `PKFastEmbed` + `CPKFastEmbed` | In-process MiniLM backend (Rust bridge + system wrapper) | Embedding API surface, runtime orchestration |
| `PKOpenAIProvider` / `PKOpenRouterProvider` / `PKOllamaProvider` / `PKAnthropicProvider` / `PKFoundationModelsProvider` | Concrete provider clients, provider-specific conversions, convenience registration/init APIs | Runtime orchestration, prompt-tree internals |

## Conventions

- Swift 6 concurrency: `Sendable`, actor isolation, no shared mutable state.
- Composition over inheritance. Narrow protocols. Explicit `throws`.
- Structured logging via `PKShared`.
- Errors: `PKError` (via `ErrorKit`) with `PKErrorDomain`, stable `errorCode`, `userFriendlyMessage` (+ `remediation` where applicable). Surface nested errors with `ErrorKit.userFriendlyMessage(for:)`; keep `localizedDescription` for low-level diagnostics.
- Tests accompany change; use `PKTestSupport`. Fixtures deterministic + lightweight; prefer reusable builders over inline setup.
- Keep `PositronicKitExamples` compiling and current with public APIs.
- Schema: prefer `JSONSchema`/`JSONSchemaBuilder`, derive from `@Schemable` when schema mirrors Swift model; no custom schema wrapper types.
- `swift build && swift test` before opening/updating PRs.
- Public API changes: update `CHANGELOG.md` under `Unreleased`, follow `docs/Releasing.md` for tag/pin workflow — `main` is not consumer source of truth.

## PositronicKit Invariants

- Transport-neutral. Concrete networking, RPC, hosting belong downstream.
- Concrete providers downstream from `PositronicKit`: provider SDK adapters live in
  dedicated provider targets, not core runtime target.
- Downstream pluggability non-negotiable: persistence, workspace resolution, tool
  execution, prompting, UI/network layers all injectable.
- Consume `PKPrompt` artifacts (`AssembledPrompt`, `RenderedPrompt`). Never reimplement
  prompt-tree semantics.
- Extension points: persistence protocols, `WorkspaceCreating`/`WorkspaceProtocol`,
  `PromptSectionProviding`, `ToolRouter`, `ChatTurnPlugin`.
- Primary entry point: `PositronicKit` facade (`final class` config owner). Smallest
  operation tier: one-shot `complete(_:)`/`stream(_:)`, `Conversation` cursors,
  `timelineManager` + `run(...)`, `agenticRuntime(...)`, or raw public seams
  (`TimelineManager`, `ToolRouter`, persistence/workspace protocols).
- Core public types: `Timeline`, `AgentInstance`, `TimelineManager`, `ToolRouter`,
  `WorkspaceManager`. `ChatEngine` + turn pipeline internal implementation details
  (driven through facade).

## PKPrompt Invariants

- `PromptNode` = canonical internal IR. `PromptBuilder` composes structural `Prompt`
  values; `PromptAssembly` lowers to nodes.
- `AssembledPrompt` = validated section artifact. `RenderedPrompt` = canonical render output.
- `PromptJournal` = prompt-history primitive. Cache policies determine lifecycle:
  stable → materialized base, semi-stable → overlays until `compact()`, volatile →
  current-only, stable mutations → hard reset.
- Author prompts via `var body: some Prompt`, composing `SystemPrompt`, `TextPrompt`,
  `UserPrompt`, `HistoryPrompt`, custom `Prompt` types.
- Trait modifiers (`.priority(...)`, `.compression(...)`, `.cachePolicy(...)`) inherit
  through subtree; resolved once at assembly.
- Three consumption layers: `Prompt → String` | `Prompt → AssembledPrompt → RenderedPrompt` |
  `RenderedPrompt → PromptJournal`.

## Workflow & Issue Tracking

PositronicKit is a standalone repo (`github.com/phynics/PositronicKit`). **Open work,
plans, and tickets are tracked as GitHub issues directly on `phynics/PositronicKit`** —
not as local ticket files and not via an in-repo `workflow/` directory. The historical
`workflow/PositronicKit/` artifact set (plans, specs, archived tickets) was removed;
any needed context is captured in the relevant GitHub issues or `docs/`.

Common ops via `gh` CLI:

- `gh issue list --state open` — list open issues
- `gh issue create --title "..." --body "..."` — new issue
- `gh issue view <number>` — inspect one issue
- `gh issue close <number>` — close issue

### Downstream consumer compatibility

Since v1.0, PositronicKit follows semver and downstream consumers pin to released
versions. You do **not** need to build or test Monad, Shuttle, or Yakamoz as part of every
PositronicKit change. Consumer build/test gates are run later, against the tagged
PositronicKit release, following [`docs/Releasing.md`](docs/Releasing.md). Use the
documented local-path override only when a specific consumer change is being developed
in tandem with an unreleased PositronicKit API.
