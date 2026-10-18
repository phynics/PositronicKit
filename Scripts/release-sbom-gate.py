#!/usr/bin/env python3
"""Bind a release-gate SBOM artifact to the exact resolved tag commit.

The Release Gate workflow resolves a release tag to one commit, pins every gate
job to that commit, and writes a provenance document beside the SBOM. The
Release SBOM workflow checks out the tag, resolves the same commit from its own
checkout, and attaches an artifact only when the provenance names that commit.
A tag that moved after its gate ran is rejected instead of silently attaching
the older commit's SBOM.

`resolve-tag`, `write-provenance`, `validate-provenance`, and `select` are the
entry points the workflows call. The lookup and provenance helpers are pure so
the gate-script tests can exercise push and dispatch runs without a remote.
"""

from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
SCHEMA = "positronickit-release-gate-provenance/1"
TAG_PATTERN = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+(?:-rc\.[0-9]+)?$")
COMMIT_PATTERN = re.compile(r"^[0-9a-f]{40}$")
GATE_WORKFLOW = "release-gate.yml"
ARTIFACT_NAME = "release-sbom"
PROVENANCE_SUFFIX = ".provenance.json"
SBOM_SUFFIX = ".cyclonedx.json"
RUNS_PER_PAGE = 100


class GateError(Exception):
    """A release-gate lookup, download, or provenance failure."""


def provenance_name(tag: str) -> str:
    return f"PositronicKit-{tag}{PROVENANCE_SUFFIX}"


def sbom_name(tag: str) -> str:
    return f"PositronicKit-{tag}{SBOM_SUFFIX}"


def gate_run_title(tag: str) -> str:
    return f"Release gate for {tag}"


def validate_tag(tag: str) -> None:
    if TAG_PATTERN.fullmatch(tag) is None:
        raise GateError(f"invalid release tag: {tag!r}")


def git(repository: Path, *arguments: str) -> str:
    result = subprocess.run(
        ("git", *arguments), cwd=repository, check=False, text=True,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    )
    if result.returncode:
        raise GateError(result.stderr.strip() or f"git {' '.join(arguments)} failed")
    return result.stdout.strip()


def resolve_tag_commit(
    tag: str, *, repository: Path = ROOT, revision: str = "HEAD"
) -> str:
    """Return the checked-out commit, requiring it to be the named tag's commit."""
    validate_tag(tag)
    head = git(Path(repository), "rev-parse", revision)
    tag_commit = git(Path(repository), "rev-parse", f"refs/tags/{tag}^{{commit}}")
    if head != tag_commit:
        raise GateError(f"{tag} resolves to {tag_commit}, not the checked-out {head}")
    if COMMIT_PATTERN.fullmatch(head) is None:
        raise GateError(f"resolved tag commit is not a full commit SHA: {head!r}")
    return head


def write_provenance(path: Path, tag: str, commit: str) -> None:
    validate_tag(tag)
    if COMMIT_PATTERN.fullmatch(commit) is None:
        raise GateError(f"provenance commit is not a full commit SHA: {commit!r}")
    destination = Path(path)
    destination.parent.mkdir(parents=True, exist_ok=True)
    document = {"schema": SCHEMA, "tag": tag, "commit": commit}
    destination.write_text(json.dumps(document, indent=2) + "\n", encoding="utf-8")


def read_provenance(path: Path) -> dict:
    source = Path(path)
    try:
        text = source.read_text(encoding="utf-8")
    except OSError as error:
        raise GateError(f"could not read provenance {source}: {error}") from error
    try:
        document = json.loads(text)
    except json.JSONDecodeError as error:
        raise GateError(f"provenance {source} is not valid JSON: {error}") from error
    if not isinstance(document, dict):
        raise GateError(f"provenance {source} must be a JSON object")
    return document


def provenance_errors(provenance: object, tag: str, commit: str) -> list[str]:
    if not isinstance(provenance, dict):
        return ["provenance is missing or not an object"]
    errors: list[str] = []
    if provenance.get("schema") != SCHEMA:
        errors.append(f"unexpected provenance schema: {provenance.get('schema')!r}")
    if provenance.get("tag") != tag:
        errors.append(f"provenance tag {provenance.get('tag')!r} does not match {tag!r}")
    recorded = provenance.get("commit")
    if not isinstance(recorded, str) or COMMIT_PATTERN.fullmatch(recorded) is None:
        errors.append(f"provenance commit is not a full commit SHA: {recorded!r}")
    elif recorded != commit:
        errors.append(f"provenance commit {recorded} does not match the release checkout {commit}")
    return errors


def validate_provenance(provenance: object, tag: str, commit: str) -> None:
    errors = provenance_errors(provenance, tag, commit)
    if errors:
        raise GateError("; ".join(errors))


def candidate_gate_runs(runs: object, tag: str) -> list[dict]:
    """Return successful Release Gate runs whose title names this tag."""
    if not isinstance(runs, list):
        return []
    title = gate_run_title(tag)
    return [
        run for run in runs
        if isinstance(run, dict)
        and run.get("conclusion") == "success"
        and run.get("display_title") == title
    ]


def select_gate_run(runs: object, tag: str, commit: str, *, load_provenance) -> dict | None:
    """Return the newest candidate whose artifact provenance matches `commit`."""
    for run in candidate_gate_runs(runs, tag):
        try:
            provenance = load_provenance(run)
        except GateError:
            continue
        if not provenance_errors(provenance, tag, commit):
            return run
    return None


def fetch_gate_runs(repository: str) -> list[dict]:
    endpoint = (
        f"repos/{repository}/actions/workflows/{GATE_WORKFLOW}"
        f"/runs?per_page={RUNS_PER_PAGE}"
    )
    result = subprocess.run(
        ("gh", "api", endpoint), check=False, text=True,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    )
    if result.returncode:
        raise GateError(result.stderr.strip() or "gh api failed")
    try:
        payload = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise GateError(f"gh api returned invalid JSON: {error}") from error
    runs = payload.get("workflow_runs")
    if not isinstance(runs, list):
        raise GateError("gh api response has no workflow_runs list")
    return runs


def download_gate_artifact(run_id: object, directory: Path) -> Path:
    target = Path(directory) / str(run_id)
    if target.exists():
        shutil.rmtree(target)
    target.mkdir(parents=True)
    result = subprocess.run(
        ("gh", "run", "download", str(run_id), "--name", ARTIFACT_NAME, "--dir", str(target)),
        check=False, text=True,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    )
    if result.returncode:
        raise GateError(result.stderr.strip() or f"could not download {ARTIFACT_NAME} for run {run_id}")
    return target


def provenance_loader(tag: str, directory: Path):
    """Build a loader that downloads one run's artifact and reads its provenance."""
    def load(run: dict) -> dict:
        target = download_gate_artifact(run["id"], directory)
        provenance_path = target / provenance_name(tag)
        if not provenance_path.is_file():
            raise GateError(f"run {run['id']} has no {provenance_name(tag)}")
        sbom_path = target / sbom_name(tag)
        if not sbom_path.is_file() or sbom_path.stat().st_size == 0:
            raise GateError(f"run {run['id']} has no non-empty {sbom_name(tag)}")
        return read_provenance(provenance_path)
    return load


def select_artifact(repository: str, tag: str, commit: str, directory: Path) -> tuple[dict, Path]:
    validate_tag(tag)
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    runs = fetch_gate_runs(repository)
    run = select_gate_run(runs, tag, commit, load_provenance=provenance_loader(tag, directory))
    if run is None:
        raise GateError(f"no successful Release Gate run for {tag} at commit {commit}")
    return run, directory / str(run["id"])


def resolve_command(arguments: argparse.Namespace) -> int:
    commit = resolve_tag_commit(
        arguments.tag, repository=arguments.repository, revision=arguments.revision
    )
    print(f"tag={arguments.tag}")
    print(f"commit={commit}")
    return 0


def write_command(arguments: argparse.Namespace) -> int:
    write_provenance(arguments.output, arguments.tag, arguments.commit)
    return 0


def validate_command(arguments: argparse.Namespace) -> int:
    provenance = read_provenance(arguments.provenance)
    validate_provenance(provenance, arguments.tag, arguments.commit)
    return 0


def select_command(arguments: argparse.Namespace) -> int:
    run, target = select_artifact(
        arguments.repository, arguments.tag, arguments.commit, Path(arguments.directory)
    )
    print(f"run_id={run['id']}")
    print(f"directory={target}")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    resolve = subparsers.add_parser("resolve-tag", help="resolve the checked-out tag to its commit")
    resolve.add_argument("--tag", required=True)
    resolve.add_argument("--repository", type=Path, default=ROOT)
    resolve.add_argument("--revision", default="HEAD")
    resolve.set_defaults(handler=resolve_command)

    write = subparsers.add_parser("write-provenance", help="write a gate artifact provenance file")
    write.add_argument("--tag", required=True)
    write.add_argument("--commit", required=True)
    write.add_argument("--output", required=True, type=Path)
    write.set_defaults(handler=write_command)

    validate = subparsers.add_parser("validate-provenance", help="validate provenance against a commit")
    validate.add_argument("--tag", required=True)
    validate.add_argument("--commit", required=True)
    validate.add_argument("--provenance", required=True, type=Path)
    validate.set_defaults(handler=validate_command)

    select = subparsers.add_parser("select", help="download and select a matching gate artifact")
    select.add_argument("--repository", required=True)
    select.add_argument("--tag", required=True)
    select.add_argument("--commit", required=True)
    select.add_argument("--directory", required=True)
    select.set_defaults(handler=select_command)

    return parser


def main() -> int:
    arguments = build_parser().parse_args()
    try:
        return arguments.handler(arguments)
    except GateError as error:
        print(f"release-sbom-gate: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
