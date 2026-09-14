# PositronicKit agent guide

PositronicKit is an embeddable Swift runtime for agentic applications. `main` contains the
unreleased Next / v5 line. Favor a coherent domain model, narrow module boundaries, durable Turn
semantics, and a small public API over new execution paths or compatibility layers.

## Decide from the source of truth

- Use source, tests, `Package.swift`, and generated build artifacts for current behavior.
- Use accepted [ADRs](docs/adr/) for architectural rationale and [CONTEXT-MAP.md](CONTEXT-MAP.md)
  with its linked glossaries for canonical vocabulary.
- Use GitHub Issues and PRs for planned work and delivery history. Do not create local ticket
  archives or private planning documents.
- Use current guides, [README.md](README.md), and [CHANGELOG.md](CHANGELOG.md) for published claims.
  Tagged release documentation is immutable.

When sources disagree, describe current behavior from code and tests. Resolve intended architecture
through the owning issue or an ADR.

## Preserve runtime boundaries

- A Turn runs on a Timeline. Managed execution derives Agent context from the attached Agent. A
  detached Timeline uses the explicit direct path.
- One `TimelineRuntimeRepository` owns Timeline metadata, append-only history, Turn admission, tool
  intent and results, terminal outcomes, replay, and Request-ID uniqueness.
- Ordinary Workspaces bind exclusively to Timelines. One deterministic dispatcher executes Workspace
  tools with process-local FIFO serialization per Workspace.
- Turn admission captures execution authority. That authority does not change while the Turn runs.
- Public consumers use capability values and handles. Managers, registries, pipeline topology, and
  model-round machinery remain internal.
- `PKContracts` imports no PositronicKit project target. Providers and external integrations do not
  import the runtime. `PKUtilities` is not a public product.
- `PromptJournal` observes assembled prompt state. It does not own semantic Timeline history.

Require an owning issue and an independently justified consumer story before adding a public
product, protocol, plugin bus, compatibility alias, or migration path.

## Verify on the supported platform

Run `make doctor` before a full gate.

- On macOS, run `make verify`.
- On Linux, run `make agent-verify` through the repository-owned Podman runner. Use
  `make agent-test FILTER='…'` for a focused test.
- Run `make verify-products`, `make verify-examples`, or `make verify-pktestsupport` when a focused
  product check helps during development.

On Linux, use the pinned Podman environment. Do not run host Swift or compose another container
command. See [docs/Development.md](docs/Development.md) for setup.

For an intentional public API change, inspect `make verify-public-api` on every affected platform
before running `make update-public-api-baseline`. Generate the Linux baseline on Linux.

For documentation or product-catalog changes, edit [docs/catalog.json](docs/catalog.json) only when
the stable ref, product graph, or navigation changes. Then run
`python3 Scripts/generate-doc-navigation.py` and `make verify-documentation`. Treat generated
navigation, landing pages, and `llms.txt` as outputs.

## Follow the concurrency policy

Use actor isolation for asynchronous state, `Synchronization.Mutex<State>` for synchronous state,
`AsyncStream` for repeated signals, and structured task ownership for child work.

Do not add a generic reference box to silence a `Sendable` error or to mutate state from an
asynchronous closure.

Document every `@unchecked Sendable`, `NSLock`, stored continuation or task, and `Box`-named holder
in `docs/Concurrency/exception-manifest.md`. Add
`// swiftlint:disable:this <rule> -- <reason>` at the site. `make verify-concurrency-scan` enforces
the policy.

## Deliver one bounded change

1. Find or create the owning GitHub issue before architectural or breaking work.
2. Keep one behavior change per PR and preserve downstream seams.
3. Add deterministic tests. Update current docs for public changes and add consumer-visible API
   changes under `CHANGELOG.md` > `Unreleased`.
4. Before closing an issue, complete its Delivery section with the PR, merge commit, exact
   verification, docs or ADR impact, and follow-up work.
5. Keep tagged release documentation separate from Next/main documentation.

## Load detailed guidance when needed

- For domain terms or ownership, read [CONTEXT-MAP.md](CONTEXT-MAP.md) and its linked glossaries.
- For runtime boundaries or design rationale, read [docs/Architecture.md](docs/Architecture.md) and
  the accepted [ADRs](docs/adr/).
- For application integration, read [docs/Setup.md](docs/Setup.md).
- For contributor setup and platform gates, read [docs/Development.md](docs/Development.md).
- For test layers, tags, and the fast loop, read [docs/Testing.md](docs/Testing.md).
- For tags, release artifacts, or API baselines, read [docs/Releasing.md](docs/Releasing.md).
