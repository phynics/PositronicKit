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

1. Merge every intended change into `CHANGELOG.md` under `Unreleased` and resolve every release
   milestone P0/P1 blocker.
2. Review the public API inventory with `make verify-public-api` on Linux and macOS. The platform
   graphs differ, especially for Apple-only products, so the release requires reviewed
   `api/4.0-public-api-linux.json` and `api/4.0-public-api-macos.json` files. For an intentional
   contract change, inspect the reported symbols and record that platform with
   `make update-public-api-baseline`; never update a baseline merely to make the gate pass. The
   checker uses the output directory reported by SwiftPM and validates every catalog module before
   treating extraction status as a failure, so errors for non-public test targets are tooling noise
   only when all reviewed public graphs are present.
3. Update `docs/catalog.json` when the stable tag, product graph, or navigation changes; regenerate
   navigation with `python3 Scripts/generate-doc-navigation.py`.
4. Confirm the stable landing remains the default and all Next links target `main`.
5. Run the applicable verification gates:

| Change scope | Required gate |
| -------------- | --------------- |
| Core runtime, prompt, shared-contract, or docs-only release work | `make verify` |
| Public product graph, examples, or package-layout changes | `make verify` and `make verify-products` |
| Linux compatibility changes | `make agent-verify` |

6. Re-run any product-specific or platform-specific gates that changed behavior on the host you
   are releasing from.

On Linux, use `make agent-verify` as the release gate. It runs the product, example,
PKTestSupport, and default-test gates inside the pinned Podman environment. If an
agent sandbox blocks Podman, rerun the same command with escalated container-runtime permissions;
do not fall back to host Swift or compose an ad hoc container command.

## Tagging Steps

1. Move the completed `Unreleased` notes into a dated version section, update
   `docs/catalog.json` stable version/ref to the same version, regenerate documentation, and commit
   the release artifacts.
2. Cut an annotated tag from that verified commit using the bare semver string, for example
   `git tag -a 4.0.0 -m 'PositronicKit 4.0.0'`.
3. Run `make verify-release VERSION=4.0.0`. This requires a clean tree, checks that the annotated
   tag points to `HEAD`, and verifies that the catalog, changelog, and generated stable docs agree.
4. Push the commit and tag, then publish the GitHub release from the matching changelog entry and
   close the matching milestone.
5. Read back the tag, GitHub release, milestone, stable landing, and changelog links. After those
   artifacts agree, downstream consumers may bump their pins to the new release.

Use an annotated tag. Do not tag unreleased work or skip the changelog entry.

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
