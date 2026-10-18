#!/usr/bin/env python3
"""Fail-closed tests for Scripts/release-sbom-gate.py.

The release gate binds an SBOM artifact to the commit a tag resolved to and
records that commit as provenance. The Release SBOM workflow attaches an
artifact only when its provenance matches the release checkout, so a tag that
moved after its gate ran is rejected instead of attaching the older commit's
SBOM. These cases cover the pure provenance checks and the full lookup plus
artifact flow for push and dispatch gate runs, with a fake `gh` on PATH so no
remote or tag mutation is needed.
"""

from __future__ import annotations

import importlib.util
import json
import os
import shutil
import stat
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "Scripts/release-sbom-gate.py"

COMMIT_A = "a" * 40
COMMIT_B = "b" * 40
TAG = "7.0.0"


def load_module():
    spec = importlib.util.spec_from_file_location("release_sbom_gate", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


MODULE = load_module()


def provenance(tag: str = TAG, commit: str = COMMIT_B, schema: str = MODULE.SCHEMA) -> dict:
    return {"schema": schema, "tag": tag, "commit": commit}


def run_command(arguments: list[str], *, env: dict | None = None, cwd: Path = ROOT):
    return subprocess.run(
        ["python3", str(SCRIPT), *arguments],
        cwd=cwd,
        env=env,
        capture_output=True,
        text=True,
        check=False,
    )


def write_fake_gh(directory: Path, runs: list[dict], artifacts: Path) -> dict[str, str]:
    """Write a `gh` stub that serves a runs payload and copies run artifacts."""
    runs_file = directory / "runs.json"
    runs_file.write_text(json.dumps({"workflow_runs": runs}), encoding="utf-8")
    fake = directory / "gh"
    fake.write_text(
        "#!/usr/bin/env bash\n"
        "set -euo pipefail\n"
        'if [ "${1:-}" = "api" ]; then\n'
        '  cat "$FAKE_GH_RUNS"\n'
        "  exit 0\n"
        "fi\n"
        'if [ "${1:-}" = "run" ] && [ "${2:-}" = "download" ]; then\n'
        "  run_id=\"$3\"\n"
        "  shift 3\n"
        "  target=\"\"\n"
        '  while [ "$#" -gt 0 ]; do\n'
        '    case "$1" in\n'
        "      --dir) target=\"$2\"; shift 2 ;;\n"
        "      *) shift ;;\n"
        "    esac\n"
        "  done\n"
        '  source_dir="$FAKE_GH_ARTIFACTS/$run_id"\n'
        '  if [ ! -d "$source_dir" ]; then\n'
        '    echo "no artifact for run $run_id" >&2\n'
        "    exit 1\n"
        "  fi\n"
        '  mkdir -p "$target"\n'
        '  cp -R "$source_dir"/. "$target"/\n'
        "  exit 0\n"
        "fi\n"
        'echo "unexpected gh invocation: $*" >&2\n'
        "exit 1\n",
        encoding="utf-8",
    )
    fake.chmod(fake.stat().st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)
    environment = dict(os.environ)
    environment["PATH"] = f"{directory}{os.pathsep}{environment.get('PATH', '')}"
    environment["FAKE_GH_RUNS"] = str(runs_file)
    environment["FAKE_GH_ARTIFACTS"] = str(artifacts)
    return environment


def make_artifact(
    artifacts: Path,
    run_id: int,
    *,
    tag: str = TAG,
    commit: str = COMMIT_B,
    with_provenance: bool = True,
    with_sbom: bool = True,
    provenance_tag: str | None = None,
) -> None:
    directory = artifacts / str(run_id)
    directory.mkdir(parents=True, exist_ok=True)
    if with_sbom:
        (directory / MODULE.sbom_name(tag)).write_text('{"bomFormat": "CycloneDX"}\n', encoding="utf-8")
    if with_provenance:
        document = provenance(tag=provenance_tag if provenance_tag is not None else tag, commit=commit)
        (directory / MODULE.provenance_name(tag)).write_text(json.dumps(document), encoding="utf-8")


def gate_run(run_id: int, *, tag: str = TAG, event: str = "push", conclusion: str = "success") -> dict:
    return {
        "id": run_id,
        "event": event,
        "conclusion": conclusion,
        "display_title": MODULE.gate_run_title(tag),
    }


def test_provenance_roundtrips() -> None:
    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory) / "provenance.json"
        MODULE.write_provenance(path, TAG, COMMIT_B)
        assert MODULE.read_provenance(path) == provenance(), MODULE.read_provenance(path)


def test_write_provenance_rejects_invalid_tag() -> None:
    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory) / "provenance.json"
        try:
            MODULE.write_provenance(path, "not-a-version", COMMIT_B)
        except MODULE.GateError:
            return
    raise AssertionError("an invalid tag must be rejected")


def test_validate_provenance_accepts_the_matching_commit() -> None:
    MODULE.validate_provenance(provenance(), TAG, COMMIT_B)


def test_validate_provenance_rejects_a_moved_tag() -> None:
    errors = MODULE.provenance_errors(provenance(commit=COMMIT_A), TAG, COMMIT_B)
    assert any(COMMIT_A in error and "does not match" in error for error in errors), errors


def test_validate_provenance_rejects_a_mismatched_tag() -> None:
    errors = MODULE.provenance_errors(provenance(tag="7.0.1"), TAG, COMMIT_B)
    assert any("does not match" in error for error in errors), errors


def test_validate_provenance_rejects_a_missing_document() -> None:
    errors = MODULE.provenance_errors(None, TAG, COMMIT_B)
    assert errors, errors


def test_validate_provenance_rejects_a_wrong_schema() -> None:
    errors = MODULE.provenance_errors(provenance(schema="something/else"), TAG, COMMIT_B)
    assert any("schema" in error for error in errors), errors


def test_candidate_gate_runs_filters_by_title_and_conclusion() -> None:
    runs = [
        gate_run(1, event="push"),
        gate_run(2, tag="7.0.1"),
        gate_run(3, conclusion="failure"),
        gate_run(4, event="workflow_dispatch"),
    ]
    candidates = MODULE.candidate_gate_runs(runs, TAG)
    assert [run["id"] for run in candidates] == [1, 4], candidates


def test_select_gate_run_prefers_a_matching_provenance() -> None:
    runs = [gate_run(1, event="workflow_dispatch"), gate_run(2, event="push")]
    documents = {1: provenance(commit=COMMIT_A), 2: provenance(commit=COMMIT_B)}
    run = MODULE.select_gate_run(
        runs, TAG, COMMIT_B, load_provenance=lambda candidate: documents[candidate["id"]]
    )
    assert run is not None and run["id"] == 2, run


def test_resolve_tag_commit_binds_the_tag_to_head() -> None:
    with tempfile.TemporaryDirectory() as directory:
        repository = Path(directory)
        subprocess.run(("git", "init", "-q", str(repository)), check=True)
        subprocess.run(("git", "-C", str(repository), "config", "user.email", "t@example.com"), check=True)
        subprocess.run(("git", "-C", str(repository), "config", "user.name", "Test"), check=True)
        (repository / "README.md").write_text("x\n", encoding="utf-8")
        subprocess.run(("git", "-C", str(repository), "add", "README.md"), check=True)
        subprocess.run(("git", "-C", str(repository), "commit", "-q", "-m", "init"), check=True)
        subprocess.run(("git", "-C", str(repository), "tag", "-a", TAG, "-m", TAG), check=True)
        commit = subprocess.check_output(
            ("git", "-C", str(repository), "rev-parse", "HEAD"), text=True
        ).strip()
        assert MODULE.resolve_tag_commit(TAG, repository=repository) == commit


def test_resolve_tag_commit_rejects_a_moved_tag() -> None:
    with tempfile.TemporaryDirectory() as directory:
        repository = Path(directory)
        subprocess.run(("git", "init", "-q", str(repository)), check=True)
        subprocess.run(("git", "-C", str(repository), "config", "user.email", "t@example.com"), check=True)
        subprocess.run(("git", "-C", str(repository), "config", "user.name", "Test"), check=True)
        (repository / "README.md").write_text("x\n", encoding="utf-8")
        subprocess.run(("git", "-C", str(repository), "add", "README.md"), check=True)
        subprocess.run(("git", "-C", str(repository), "commit", "-q", "-m", "init"), check=True)
        (repository / "README.md").write_text("y\n", encoding="utf-8")
        subprocess.run(("git", "-C", str(repository), "commit", "-q", "-am", "second"), check=True)
        subprocess.run(("git", "-C", str(repository), "tag", "-a", TAG, "-m", TAG, "HEAD~1"), check=True)
        try:
            MODULE.resolve_tag_commit(TAG, repository=repository)
        except MODULE.GateError:
            return
    raise AssertionError("a tag that does not point at HEAD must be rejected")


def _select_case(name: str, runs: list[dict], artifacts: list[tuple], expected_exit: int, expected_run: int | None) -> None:
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        artifact_root = root / "artifacts"
        for entry in artifacts:
            run_id, options = entry
            make_artifact(artifact_root, run_id, **options)
        environment = write_fake_gh(root, runs, artifact_root)
        output = root / "gate"
        result = run_command(
            [
                "select",
                "--repository", "phynics/PositronicKit",
                "--tag", TAG,
                "--commit", COMMIT_B,
                "--directory", str(output),
            ],
            env=environment,
        )
        assert result.returncode == expected_exit, f"{name}: {result.stdout}{result.stderr}"
        if expected_run is not None:
            assert f"run_id={expected_run}" in result.stdout, f"{name}: {result.stdout}"
            assert f"directory={output / str(expected_run)}" in result.stdout, result.stdout
        else:
            assert "no successful Release Gate run" in result.stderr, result.stderr


def test_select_accepts_a_matching_push_run() -> None:
    runs = [gate_run(101, event="push")]
    _select_case("push", runs, [(101, {"commit": COMMIT_B})], 0, 101)


def test_select_accepts_a_matching_dispatch_run() -> None:
    dispatch_run = gate_run(102, event="workflow_dispatch")
    dispatch_run["head_sha"] = COMMIT_A  # Dispatch runs report the workflow branch, not the tag.
    runs = [dispatch_run]
    _select_case("dispatch", runs, [(102, {"commit": COMMIT_B})], 0, 102)


def test_select_rejects_a_moved_tag() -> None:
    runs = [gate_run(103, event="push")]
    _select_case("moved", runs, [(103, {"commit": COMMIT_A})], 1, None)


def test_select_rejects_a_mismatched_tag() -> None:
    runs = [gate_run(104, event="workflow_dispatch")]
    _select_case("wrong-tag", runs, [(104, {"provenance_tag": "7.0.1"})], 1, None)


def test_select_rejects_missing_provenance() -> None:
    runs = [gate_run(105, event="push")]
    _select_case("missing", runs, [(105, {"with_provenance": False})], 1, None)


def test_select_skips_a_stale_run_and_picks_the_match() -> None:
    runs = [gate_run(106, event="workflow_dispatch"), gate_run(107, event="push")]
    _select_case("skip-stale", runs, [(106, {"commit": COMMIT_A}), (107, {"commit": COMMIT_B})], 0, 107)


if __name__ == "__main__":
    tests = [
        test_provenance_roundtrips,
        test_write_provenance_rejects_invalid_tag,
        test_validate_provenance_accepts_the_matching_commit,
        test_validate_provenance_rejects_a_moved_tag,
        test_validate_provenance_rejects_a_mismatched_tag,
        test_validate_provenance_rejects_a_missing_document,
        test_validate_provenance_rejects_a_wrong_schema,
        test_candidate_gate_runs_filters_by_title_and_conclusion,
        test_select_gate_run_prefers_a_matching_provenance,
        test_resolve_tag_commit_binds_the_tag_to_head,
        test_resolve_tag_commit_rejects_a_moved_tag,
        test_select_accepts_a_matching_push_run,
        test_select_accepts_a_matching_dispatch_run,
        test_select_rejects_a_moved_tag,
        test_select_rejects_a_mismatched_tag,
        test_select_rejects_missing_provenance,
        test_select_skips_a_stale_run_and_picks_the_match,
    ]
    for test in tests:
        test()
    print(f"release-sbom-gate script tests passed ({len(tests)} tests)")
