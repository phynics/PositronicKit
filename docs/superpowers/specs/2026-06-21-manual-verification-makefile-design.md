# Manual Verification Makefile Design

## Goal

Replace GitHub-hosted CI jobs with explicit local Make targets while preserving
the existing verification coverage. MiniLM verification remains a separate,
opt-in path because it builds a Rust bridge and downloads pinned model assets.

## Interface

- `make verify` builds the default package, validates documentation, audits the
  default Apple build for accidental PKFastEmbed linkage, and runs Swift tests.
- `make verify-minilm` bootstraps PKFastEmbed and pinned MiniLM assets, exports
  the required native paths, runs trait-enabled MiniLM contract tests, and runs
  the companion package tests.
- `make verify-products` builds every supported Swift package product. This is
  the manual portability check intended for Linux and other supported hosts.
- Existing `build`, `test`, `test-parallel`, `harden`, and `clean` commands stay
  available.

## Implementation

Delete `.github/workflows/ci.yml`. Extend the root `Makefile` with composable
targets for the default linkage audit, product builds, native bootstrap, and
MiniLM tests. Use overridable Make variables for the PKFastEmbed installation
prefix and model directory, defaulting to `.build` paths inside the repository.

Update `README.md` so contributors can discover the manual verification paths
and understand that `verify-minilm` may download assets from the pinned model
revision.

## Failure Behavior

Every verification target stops on the first failing command. The default
linkage audit fails when the verbose build log contains PKFastEmbed or the Apple
MiniLM trait backend. MiniLM bootstrap retains checksum validation from
`Scripts/bootstrap-minilm-ci.sh`.

## Verification

- Parse the Makefile with `make -n` for each new top-level target.
- Run `make verify` locally.
- Run lightweight/native unit checks that do not require downloading assets.
- Confirm `.github/workflows/ci.yml` is removed and documentation references the
  replacement commands.
- Run `git diff --check`.

