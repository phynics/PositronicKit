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

## Before Tagging

1. Merge every intended change into `CHANGELOG.md` under `Unreleased` and close out the open
   issues the release claims to deliver.
2. Review the public API inventory with `make verify-public-api` on Linux and macOS. The platform
   graphs differ, especially for Apple-only products, so the release requires reviewed
   `api/<major>.<minor>-public-api-linux.json` and `api/<major>.<minor>-public-api-macos.json`
   files. For an intentional contract change, inspect the reported symbols and record that platform
   with `make update-public-api-baseline`; never update a baseline merely to make the gate pass. The
   checker uses the output directory reported by SwiftPM and validates every catalog module before
   treating extraction status as a failure, so errors for non-public test targets are tooling noise
   only when all reviewed public graphs are present.
3. Generate the macOS baseline on macOS. A Linux host cannot extract the Apple-only graph, so a
   release prepared on Linux is not ready to tag until a macOS host has run
   `make verify-public-api` (or `make update-public-api-baseline`) against the same commit.
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
3. Cut an annotated tag from that merged commit using the bare semver string, for example
   `git tag -a <version> -m 'PositronicKit <version>'`.
4. Run `make verify-release VERSION=<version>`. This requires a clean tree, checks that the
   annotated tag points to `HEAD`, and verifies that the catalog, changelog, generated stable docs,
   and the release SBOM agree.
5. Push the tag, then publish the GitHub release from the matching changelog entry. The
   `Release SBOM` workflow generates the CycloneDX document at the published tag and attaches it to
   the release; no manual upload is required.
6. Read back the tag, GitHub release, stable landing, and changelog links, and confirm the tag is
   reachable from `main` (`git branch -r --contains <version>`). After those artifacts agree,
   downstream consumers may bump their pins to the new release.

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
the per-product dependency edges change: `PKOpenAIProvider` must list `MacPaw/OpenAI` while
`PKContracts` must not.

`make verify-release` runs the same generation for the tag being published, so the SBOM is a
blocking release artifact rather than an afterthought. The `Release SBOM` workflow repeats the
generation on the published tag and attaches the result to the GitHub release. Set
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
