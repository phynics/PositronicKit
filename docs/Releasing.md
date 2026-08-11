# Releasing PositronicKit

This guide describes how to ship PositronicKit releases and how downstream consumers advance to
them.

## Versioning

PositronicKit ships as a single semver release line for the whole package graph:

- `patch` for bug fixes, docs, test-only changes, and internal refactors that do not change the
  v1 compatibility contract.
- `minor` for additive, backward-compatible public API changes.
- `major` for breaking changes to the v1 compatibility contract.

The tagged version applies to the public products documented in
[README.md](../README.md) and the modules covered by [CHANGELOG.md](../CHANGELOG.md).

## Before Tagging

1. Merge every intended change into `CHANGELOG.md` under `Unreleased`.
2. Confirm the README and docs still match the public surface.
3. Run the applicable verification gates:

| Change scope | Required gate |
| -------------- | --------------- |
| Core runtime, prompt, shared-contract, or docs-only release work | `make verify` |
| Public product graph, examples, or package-layout changes | `make verify` and `make verify-products` |
| `PKLocalEmbeddings` / `PKFastEmbed` / model asset changes | `make verify`, `make verify-products`, and `make verify-minilm` |
| Linux compatibility changes | `make agent-verify` |
| Native bridge safety changes | `make verify-linux-asan` |

1. Re-run any product-specific or platform-specific gates that changed behavior on the host you
   are releasing from.

On Linux, use `make agent-verify` as the release gate. It runs the product, example,
PKTestSupport, default-test, and MiniLM-test gates inside the pinned Podman environment. If an
agent sandbox blocks Podman, rerun the same command with escalated container-runtime permissions;
do not fall back to host Swift or compose an ad hoc container command.

## Tagging Steps

1. Cut the tag from the verified commit using the bare semver string, for example `1.0.1`.
2. Push the commit and the tag.
3. Publish the GitHub release using the matching `CHANGELOG.md` entry.
4. After the tag exists, downstream consumers may bump their pins to the new release.

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

## Dry-Run Rehearsal

Before the first post-v1 patch release, rehearse this flow on a docs-only patch release (for
example `1.0.1`) and verify that the steps above still work end to end.
