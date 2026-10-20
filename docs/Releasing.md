# Releasing PositronicKit

This guide describes how to ship PositronicKit releases and how downstream consumers advance to
them.

## Versioning

PositronicKit ships one semver release line for the package graph. `docs/catalog.json` records the
latest stable tag and the complete public product/documentation catalog:

- `patch` for bug fixes, docs, test-only changes, and internal refactors that do not change the
  current stable compatibility contract.
- `minor` for additive, backward-compatible public API changes.
- `major` for breaking changes to the current stable compatibility contract.

The tagged version applies to the public products documented in
[README.md](../README.md) and the modules covered by [CHANGELOG.md](../CHANGELOG.md).

## Public API compatibility gate

`make verify-release VERSION=<version>` compares the release candidate's public symbol surface with
the frozen baseline of the previous release. It reads `api/next-public-api-<platform>.json` for a
patch release and `api/<major>.<minor>-public-api-<platform>.json` for a minor or major release,
and it compares against `api/<previous-major>.<previous-minor>-public-api-<platform>.json`. The
previous release is the dated section immediately below the candidate in `CHANGELOG.md`.

The release kind sets the rule:

| Release kind | Rule |
| ------------ | ---- |
| `patch` | Fails on any public symbol delta: added, removed, or changed declarations. |
| `minor` | Fails on a removed symbol or a changed declaration; additions are compatible. |
| `major` | Removals pass, but the dated changelog section must carry a non-empty `### Breaking` section. |

The tag workflow accepts stable tags and release candidates such as `7.0.0-rc.1`. For a release
candidate, `VERSION` is the full tag while the changelog, stable catalog ref, and frozen API
baseline use the corresponding stable version (`7.0.0`). The release-candidate gate compares the
same candidate baseline with the previous dated release.

The check depends on the frozen per-tag baselines from #259. Never edit
`api/<major>.<minor>-public-api-<platform>.json`; promote the Next graphs at release time with
`Scripts/promote-public-api-baselines.py --to <version>`.

The 6.1.0 release broke this rule before the gate existed: it removed 185 public symbols relative
to 6.0.0. The tag is immutable, so its changelog entry records the break, and consumers on
`from: "6.0.0"` must pin `exact: "6.0.x"` or move to 7.0.0.

## Experimental surfaces

Experimental public surfaces ship behind `@_spi(Experimental)`. They are excluded from the
semver-stable public API baseline and tracked in their own baselines
(`api/next-experimental-api-<platform>.json`).

- Experimental surfaces may change, evolve, or be removed in any minor release.
- Graduating an experimental surface to semver-stable public API requires an owning issue and an
  independently justified consumer story.
- Breaking changes or removals of experimental surfaces do not trigger semver-major bumps, but they
  must be documented in `CHANGELOG.md` under an `### Experimental` subsection.
- Downstream consumers access experimental surfaces by adding `@_spi(Experimental)` to module
  imports (e.g. `@_spi(Experimental) import PKContracts`).

## Before Tagging

1. Merge every intended change into `CHANGELOG.md` under `Unreleased` and close out the open
   issues the release claims to deliver.
2. Review the API inventory with `make verify-public-api` on Linux and macOS. The platform
   graphs differ, especially for Apple-only products, so the release requires reviewed
   `api/next-public-api-<platform>.json` and `api/next-experimental-api-<platform>.json` files on
   `main`. For an intentional contract change, inspect the reported symbols and record that platform
   with `make update-public-api-baseline`; never update a baseline merely to make the gate pass. The
   checker uses the output directory reported by SwiftPM and validates every catalog module before
   treating extraction status as a failure, so errors for non-public test targets are tooling noise
   only when all reviewed public graphs are present.
3. Generate the macOS Next baselines on macOS. A Linux host cannot extract the Apple-only graph, so a
   release prepared on Linux is not ready to tag until a macOS host has run
   `make verify-public-api` (or `make update-public-api-baseline`) against the same commit.
   When the macOS CI lane fails `make verify-public-api`, it publishes the regenerated files as the
   `macos-public-api-baseline` artifact. Retrieve and commit them from a Linux host:

   ```bash
   gh run download <run-id> -n macos-public-api-baseline
   cp macos-public-api-baseline/next-public-api-macos.json api/
   cp macos-public-api-baseline/next-experimental-api-macos.json api/
   ```

   The lane publishes the artifact only for an API-baseline failure and never pushes the change
   itself.
   When both platform checks pass against the current Next baseline and the symbol graphs stay
   unchanged, freeze the release baselines with:

   ```sh
   python3 Scripts/promote-public-api-baselines.py --to <release-version>
   ```

   The script copies `api/next-public-api-<platform>.json` to
   `api/<major>.<minor>-public-api-<platform>.json` and fails if that release-named file already
   exists. A frozen release baseline is never edited; `make verify-public-api-immutability` fails
   when one no longer matches its release tag.
4. Update `docs/catalog.json` when the stable tag, product graph, or navigation changes; regenerate
   navigation with `python3 Scripts/generate-doc-navigation.py`.
5. Confirm the stable landing remains the default and all Next links target `main`.
6. Run the applicable verification gates:

| Change scope | Required gate |
| -------------- | --------------- |
| Core runtime, prompt, shared-contract, or docs-only release work | `make verify` |
| Public product graph, examples, or package-layout changes | `make verify` and `make verify-products` |
| Linux compatibility changes | `make agent-verify` |

7. Re-run any product-specific or platform-specific gates that changed behavior on the host you
   are releasing from.

For a PR that adds or changes a dated release heading or changes `docs/catalog.json` stable
`version`/`ref`, the Release Gate workflow runs `make verify-release VERSION=<version> DRY_RUN=1`.
This checks the changelog, catalog, API baselines, and semver compatibility without requiring a
tag or building the SBOM. PRs that only change `Unreleased` do not run this dry run.

On Linux, use `make agent-verify` as the release gate. It runs the product, example,
PKTestSupport, and default-test gates inside the pinned container environment. If an
agent sandbox blocks the container runtime, rerun the same command with escalated permissions;
do not fall back to host Swift or compose an ad hoc container command.

## Tagging Steps

1. Move the completed `Unreleased` notes into a dated version section, update
   `docs/catalog.json` stable version/ref to the same version, regenerate documentation, and commit
   the release artifacts.
2. Land the release-artifact commit on `main` first, then tag the merged commit. Release PRs are
   squash-merged, so a tag cut on the branch points at a commit that never reaches `main`. Do not
   tag until the merge commit exists and the local `main` is fast-forwarded to it.
3. Cut an annotated tag from that merged commit, using the bare semver string or a release-candidate
   tag, for example `git tag -a <version> -m 'PositronicKit <version>'`.
4. Run `make verify-release VERSION=<version>`. This requires a clean tree, checks that the
   annotated tag points to `HEAD`, and verifies that the catalog, changelog, generated stable docs,
   the semver comparison, and the release SBOM agree. For a candidate tag such as `7.0.0-rc.1`,
   the catalog and changelog still name `7.0.0`.
5. Push the tag to start the Release Gate workflow. The workflow resolves the tag to one commit,
   pins every gate job to that commit, and waits for both its Linux and macOS readiness and semver
   jobs to pass. Its final SBOM job runs only after both jobs pass and stores the CycloneDX document
   with a provenance file naming the resolved tag commit. Then publish the GitHub release from the
   matching changelog entry. The `Release SBOM` workflow resolves the tag from its own checkout and
   attaches an SBOM only when the artifact provenance names that same commit; no manual upload is
   required.
6. Read back the tag, GitHub release, stable landing, and changelog links, and confirm the tag is
   reachable from `main` (`git branch -r --contains <version>`). After those artifacts agree,
   downstream consumers may bump their pins to the new release.

## Tag protection and mutability

Repository tag protection rules or rulesets can restrict which actors may create, update, or delete
matching tags. Configure those actor restrictions to match the release process; they control tag
mutability, not whether a workflow has passed. This repository does not have a required-workflow tag
rule, so tag creation is not blocked until the Release Gate succeeds. Do not publish a GitHub release
until both platform jobs are green.

The Release Gate records the commit resolved from the tag and pins all gate jobs to that revision.
The `Release SBOM` workflow compares the artifact provenance with the commit in its release checkout
before attaching the SBOM. If a tag has moved or been recreated since the gate ran, the old artifact
is rejected; run the gate successfully for the tag's current commit before publishing.

Use an annotated tag. Do not tag unreleased work or skip the changelog entry. Avoid updating or
deleting a published tag. If a tag must change before publication, restrict the change to authorized
release maintainers, confirm the tree is unchanged (`git rev-parse <version>^{tree}`), and run the
Release Gate again for the tag's new commit. Existing clones may need `git fetch --tags --force` to
observe an updated tag.

To run either workflow manually, select `main` as the workflow ref. For `Release Gate`, enter the
full tag in its `tag` input. A manual `Release SBOM` run requires an existing release and a
successful gate for that tag.

During the release pull request, `make verify-documentation` accepts a stable ref without a local
tag only when `CHANGELOG.md` has a dated section for that version. `make verify-release` requires
the annotated tag after the release commit reaches `main`.

Use an annotated tag. Do not tag unreleased work or skip the changelog entry. A pushed tag is
immutable in practice: if one has to move, do it before any GitHub release or downstream pin
references it, confirm the tree is unchanged (`git rev-parse <version>^{tree}`), and say so
explicitly, because consumers who already fetched it need `git fetch --tags --force`.

## Software bill of materials

SwiftPM 6.4 generates SBOMs for the package graph (SE-0509). PositronicKit publishes CycloneDX
because downstream dependency scanners read it:

```bash
make sbom VERSION=<version>
```

The target runs the accurate build-based path
(`swift build --build-system swiftbuild --sbom-spec cyclonedx`) and writes
`.build/sboms/PositronicKit-<version>.cyclonedx.json` with the release version. It fails if SwiftPM
cannot generate the document, if a public library product is missing from the components, or if
the audited attribution changes: neither `PKOpenAIProvider` nor `PKContracts` may depend on
`MacPaw/OpenAI`.

`make verify-release` runs the same generation for the tag being verified, so the SBOM is a blocking
release artifact rather than an afterthought. The Release Gate workflow generates a final SBOM only
after both platform checks succeed and stores provenance with the resolved tag commit. The
`Release SBOM` workflow checks that provenance against its release checkout before attaching the
artifact to the published GitHub release. A manual SBOM run has the same commit check. Set
`SBOM_FORMAT=spdx` to emit SPDX instead, but the release artifact stays CycloneDX.

## Downstream Cadence

- If a consumer is driving the change, keep it on a local-path override while developing, land
  the PositronicKit change, tag the compatible release, then repin the consumer in the same
  ticket.
- If a consumer is not driving the change, bump it opportunistically on the next minor release
  after its full gate passes.
- Patch releases are for fixes and housekeeping; do not make consumers chase them unless they
  need the fix.
- Keep local-path overrides out of committed manifests.

## Documentation channels

- Stable links always use the exact tag recorded in `docs/catalog.json`; tags are immutable.
- Next links use `main` and must be labeled unreleased.
- The generated root landing defaults to stable. Regenerate and commit the root, stable, Next,
  navigation, and `llms.txt` artifacts together.
