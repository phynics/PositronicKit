#!/usr/bin/env python3
"""Validate local release metadata and an annotated tag before it is pushed."""

from __future__ import annotations

import json
import re
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent

VERSION_PATTERN = re.compile(
    r"(?P<major>[0-9]+)\.(?P<minor>[0-9]+)\.(?P<patch>[0-9]+)(?:-rc\.[0-9]+)?"
)
RELEASE_HEADING_PATTERN = re.compile(
    r"^## \[(?P<version>[0-9]+\.[0-9]+\.[0-9]+)\] - \d{4}-\d{2}-\d{2}$",
    re.MULTILINE,
)
RELEASE_SECTION_PATTERN = re.compile(
    r"^## \[(?P<version>[0-9]+\.[0-9]+\.[0-9]+)\](?: - [^\n]*)?\n(.*?)(?=^## \[|\Z)",
    re.MULTILINE | re.DOTALL,
)
BREAKING_SECTION_PATTERN = re.compile(
    r"^### Breaking\s*\n(.*?)(?=^### |^## |\Z)",
    re.MULTILINE | re.DOTALL,
)
API_PLATFORMS = ("linux", "macos")
MAX_REPORTED_VIOLATIONS = 50


def fail(message: str) -> None:
    print(f"release readiness: {message}", file=sys.stderr)
    raise SystemExit(1)


def git(*arguments: str) -> str:
    result = subprocess.run(
        ("git", *arguments), cwd=ROOT, check=False, text=True,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    )
    if result.returncode:
        fail(result.stderr.strip() or f"git {' '.join(arguments)} failed")
    return result.stdout.strip()


def version_components(version: str) -> tuple[int, int, int]:
    match = VERSION_PATTERN.fullmatch(version)
    if match is None:
        fail(f"invalid semantic version: {version!r}")
    return (int(match.group("major")), int(match.group("minor")), int(match.group("patch")))


def stable_version(version: str) -> str:
    """Return the stable version represented by a stable or release-candidate tag."""
    if VERSION_PATTERN.fullmatch(version) is None:
        fail(f"invalid semantic version or release-candidate tag: {version!r}")
    return re.sub(r"-rc\.[0-9]+$", "", version)


def release_kind(version: str) -> str:
    """Classify a release by the SemVer component it advances."""
    _, minor, patch = version_components(version)
    if patch:
        return "patch"
    if minor:
        return "minor"
    return "major"


def release_versions(changelog: str) -> list[str]:
    return [match.group("version") for match in RELEASE_HEADING_PATTERN.finditer(changelog)]


def previous_release(changelog: str, version: str) -> str | None:
    """Return the dated release before `version` in the descending changelog."""
    versions = release_versions(changelog)
    try:
        index = versions.index(version)
    except ValueError:
        return None
    return versions[index + 1] if index + 1 < len(versions) else None


def release_section(changelog: str, version: str) -> str | None:
    for match in RELEASE_SECTION_PATTERN.finditer(changelog):
        if match.group("version") == version:
            return match.group(2)
    return None


def has_breaking_section(section: str) -> bool:
    match = BREAKING_SECTION_PATTERN.search(section)
    return match is not None and bool(match.group(1).strip())


def symbol_label(symbol: dict) -> str:
    return f"{symbol['module']}.{'/'.join(symbol['path'])}"


def compare_public_surfaces(candidate: dict, previous: dict, kind: str) -> list[str]:
    """Report the public symbols a release changes against its predecessor.

    A patch release may not change the public surface at all, a minor release may
    only add symbols, and a major release may change anything.
    """
    previous_symbols = {symbol["precise"]: symbol for symbol in previous.get("symbols", [])}
    candidate_symbols = {symbol["precise"]: symbol for symbol in candidate.get("symbols", [])}
    removed = sorted(set(previous_symbols) - set(candidate_symbols))
    added = sorted(set(candidate_symbols) - set(previous_symbols))
    changed = sorted(
        precise for precise in set(previous_symbols) & set(candidate_symbols)
        if previous_symbols[precise] != candidate_symbols[precise]
    )
    if kind == "major":
        return []
    failures = [
        f"removed public symbol: {symbol_label(previous_symbols[precise])}"
        for precise in removed
    ]
    if kind == "patch":
        failures += [
            f"added public symbol: {symbol_label(candidate_symbols[precise])}"
            for precise in added
        ]
    failures += [
        f"changed public symbol declaration: {symbol_label(candidate_symbols[precise])}"
        for precise in changed
    ]
    return failures


def candidate_baseline_path(root: Path, version: str, platform_name: str) -> Path:
    """Return the baseline that ships in this release.

    A minor or major release promotes its own `api/<major>.<minor>-*` file; a
    patch release keeps the frozen minor baseline and compares `api/next-*`.
    """
    major, minor, patch = version_components(version)
    release_path = root / "api" / f"{major}.{minor}-public-api-{platform_name}.json"
    if patch == 0 and release_path.exists():
        return release_path
    return root / "api" / f"next-public-api-{platform_name}.json"


def api_semver_violations(
    root: Path,
    version: str,
    changelog: str,
    platforms: tuple[str, ...] = API_PLATFORMS,
) -> list[str]:
    """Return the public API compatibility failures for a release candidate."""
    kind = release_kind(version)
    violations: list[str] = []
    if kind == "major":
        section = release_section(changelog, version)
        if section is None or not has_breaking_section(section):
            violations.append(
                f"major release {version} must carry a non-empty `### Breaking` section"
            )

    previous_version = previous_release(changelog, version)
    if previous_version is None:
        return violations
    previous_name = ".".join(previous_version.split(".")[:2])
    for platform_name in platforms:
        candidate_path = candidate_baseline_path(root, version, platform_name)
        previous_path = root / "api" / f"{previous_name}-public-api-{platform_name}.json"
        if not candidate_path.exists() or not previous_path.exists():
            print(
                f"release readiness: skipping the {kind} public API comparison for "
                f"{platform_name} (missing {candidate_path.name} or {previous_path.name})",
                file=sys.stderr,
            )
            continue
        candidate = json.loads(candidate_path.read_text())
        prior = json.loads(previous_path.read_text())
        for failure in compare_public_surfaces(candidate, prior, kind):
            violations.append(f"{failure} [{platform_name}]")
    return violations


def main() -> int:
    arguments = sys.argv[1:]
    dry_run = bool(arguments and arguments[0] == "--dry-run")
    if dry_run:
        arguments = arguments[1:]
    if len(arguments) != 1 or VERSION_PATTERN.fullmatch(arguments[0]) is None:
        fail(
            "pass VERSION as a bare semantic version or release-candidate tag, for example "
            "`make verify-release VERSION=5.0.0` or `make verify-release VERSION=7.0.0-rc.1`"
        )
    version = arguments[0]
    release = stable_version(version)

    catalog = json.loads((ROOT / "docs" / "catalog.json").read_text())
    stable = catalog["stable"]
    if stable.get("version") != release or stable.get("ref") != release:
        fail(f"docs/catalog.json stable.version and stable.ref must both equal {release}")

    changelog = (ROOT / "CHANGELOG.md").read_text()
    release_heading = re.compile(
        rf"^## \[{re.escape(release)}\] - \d{{4}}-\d{{2}}-\d{{2}}$", re.MULTILINE
    )
    if not release_heading.search(changelog):
        fail(f"CHANGELOG.md has no dated [{release}] release section")
    unreleased = re.search(r"^## \[Unreleased\]\s*(.*?)(?=^## \[)", changelog, re.MULTILINE | re.DOTALL)
    if unreleased is None or unreleased.group(1).strip():
        fail("CHANGELOG.md Unreleased must be empty after cutting the release section")

    baseline_release = ".".join(release.split(".")[:2])
    for platform_name in API_PLATFORMS:
        baseline_path = ROOT / "api" / f"{baseline_release}-public-api-{platform_name}.json"
        if not baseline_path.exists():
            fail(f"missing reviewed {platform_name} public API baseline: {baseline_path.relative_to(ROOT)}")
        baseline = json.loads(baseline_path.read_text())
        if baseline.get("release") != baseline_release or baseline.get("platform") != platform_name:
            fail(f"invalid release/platform metadata in {baseline_path.relative_to(ROOT)}")

    violations = api_semver_violations(ROOT, release, changelog)
    if violations:
        print(
            f"release readiness: {release_kind(release)} release {release} changes the public "
            "API relative to the previous release:",
            file=sys.stderr,
        )
        for violation in violations[:MAX_REPORTED_VIOLATIONS]:
            print(f"  {violation}", file=sys.stderr)
        if len(violations) > MAX_REPORTED_VIOLATIONS:
            print(f"  ... and {len(violations) - MAX_REPORTED_VIOLATIONS} more", file=sys.stderr)
        print(
            "A patch release must not change the public API, and a minor release must not remove "
            "or change symbols. Cut a major release for removals, or restore the symbols.",
            file=sys.stderr,
        )
        raise SystemExit(1)

    if dry_run:
        print(
            f"Release metadata and public API compatibility checks passed for {release} "
            "(dry run; tag, clean checkout, documentation generation, and SBOM checks skipped)."
        )
        return 0

    tag_ref = f"refs/tags/{version}"
    if git("cat-file", "-t", tag_ref) != "tag":
        fail(f"{version} must be an annotated tag")
    if git("rev-parse", f"{tag_ref}^{{commit}}") != git("rev-parse", "HEAD"):
        fail(f"{version} does not point to HEAD")
    if git("status", "--porcelain"):
        fail("working tree must be clean")

    for command in (
        ("python3", "Scripts/generate-doc-navigation.py", "--check"),
        ("python3", "Scripts/validate-documentation.py"),
    ):
        result = subprocess.run(command, cwd=ROOT, check=False)
        if result.returncode:
            return result.returncode

    # Publishing an SBOM is blocking: a release without a valid CycloneDX
    # document for its package graph does not ship. The generator also checks
    # per-product dependency attribution, so a silently changed graph fails
    # here instead of at a downstream scanner.
    sbom = subprocess.run(
        ("python3", "Scripts/generate-sbom.py", "--format", "cyclonedx", "--version", version),
        cwd=ROOT,
        check=False,
    )
    if sbom.returncode:
        fail(f"could not generate the CycloneDX release SBOM for {version}")

    print(f"Local release artifacts, stable documentation, and annotated tag {version} agree.")
    print("Confirm the release text and that the tag is reachable from main during publication.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
