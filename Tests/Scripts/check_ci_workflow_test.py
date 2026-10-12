#!/usr/bin/env python3
"""Static guardrails for the macOS public API baseline artifact flow.

GitHub Actions evaluates the workflow, so the failure-only publication rule
cannot be exercised locally. These checks read `.github/workflows/ci.yml` as
text (PyYAML is not installed in the pinned image) and fail closed when the
macOS lane stops regenerating and publishing the baseline only when
`make verify-public-api` is the failing step.

The regression this guards: `if: failure()` alone also fires after an unrelated
macOS gate failure, which would publish a misleading baseline.

The same file also guards the frozen-baseline gate wiring: `main` is checked
against `api/next-*`, editing a release-named baseline must fail the preflight
static gate, and the preflight job must run that gate. A future edit that drops
one link in the chain would silently stop failing on a frozen-file edit.
"""

from __future__ import annotations

import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github/workflows/ci.yml"
MAKEFILE = ROOT / "Makefile"
MACOS_JOB = "macos-verify"
PREFLIGHT_JOB = "preflight"
NEXT_BASELINE_SCRIPT = ROOT / "Scripts/public-api-baseline.py"
IMMUTABILITY_CHECKER = "Scripts/check-public-api-baseline-immutability.py"
PUBLIC_API_OUTCOME_CONDITION = (
    "if: failure() && steps.public-api.outcome == 'failure'"
)


def workflow_text() -> str:
    return WORKFLOW.read_text(encoding="utf-8")


def job_block(workflow: str, job: str) -> str:
    """Return the lines of one top-level job, stopping at the next job."""
    lines = workflow.splitlines()
    start = None
    for index, line in enumerate(lines):
        if line.startswith(f"  {job}:"):
            start = index
            break
    if start is None:
        raise AssertionError(f"{job} job not found in {WORKFLOW.relative_to(ROOT)}")
    end = len(lines)
    for index in range(start + 1, len(lines)):
        if re.match(r"^  [A-Za-z0-9_-]+:\s*$", lines[index]):
            end = index
            break
    return "\n".join(lines[start:end])


def makefile_text() -> str:
    return MAKEFILE.read_text(encoding="utf-8")


def target_block(makefile: str, target: str) -> str:
    """Return a Make target declaration plus its recipe, stopping at a blank line."""
    lines = makefile.splitlines()
    start = None
    for index, line in enumerate(lines):
        if line.startswith(f"{target}:"):
            start = index
            break
    if start is None:
        raise AssertionError(f"{target} target not found in {MAKEFILE.relative_to(ROOT)}")
    block = [lines[start]]
    for line in lines[start + 1 :]:
        if not line.strip() or re.match(r"^[A-Za-z0-9_.-]+:", line):
            break
        block.append(line)
    return "\n".join(block)


def permissions_block(workflow: str) -> str:
    lines = workflow.splitlines()
    start = None
    for index, line in enumerate(lines):
        if line.startswith("permissions:"):
            start = index
            break
    if start is None:
        raise AssertionError("top-level permissions block not found")
    block: list[str] = []
    for line in lines[start + 1 :]:
        if line.strip() and not line.startswith(" "):
            break
        block.append(line)
    return "\n".join(block)


def test_main_api_check_reads_the_next_baseline() -> None:
    script = NEXT_BASELINE_SCRIPT.read_text(encoding="utf-8")
    assert 'BASELINE_RELEASE = "next"' in script, script


def test_immutability_target_runs_the_checker() -> None:
    block = target_block(makefile_text(), "verify-public-api-immutability")
    assert IMMUTABILITY_CHECKER in block, block


def test_static_gate_includes_the_immutability_check() -> None:
    block = target_block(makefile_text(), "verify-static")
    assert "verify-public-api-immutability" in block, block


def test_preflight_job_runs_the_static_gate() -> None:
    job = job_block(workflow_text(), PREFLIGHT_JOB)
    assert "make verify-static" in job, job


def test_permissions_stay_read_only() -> None:
    block = permissions_block(workflow_text())
    assert re.search(r"^\s+contents:\s*read\s*$", block, re.MULTILINE), block
    assert "write" not in block, block


def test_public_api_check_is_its_own_step() -> None:
    job = job_block(workflow_text(), MACOS_JOB)
    assert "id: public-api" in job, job
    assert "make verify-public-api" in job, job


def test_regeneration_runs_only_on_public_api_failure() -> None:
    job = job_block(workflow_text(), MACOS_JOB)
    assert "make update-public-api-baseline" in job, job
    assert job.count(PUBLIC_API_OUTCOME_CONDITION) >= 2, job


def test_artifact_is_published_only_on_public_api_failure() -> None:
    job = job_block(workflow_text(), MACOS_JOB)
    assert "name: macos-public-api-baseline" in job, job
    assert "if-no-files-found: error" in job, job
    assert "${{ steps.baseline.outputs.baseline }}" in job, job
    assert "'api/next-public-api-macos.json'" in job, job


if __name__ == "__main__":
    tests = [
        test_main_api_check_reads_the_next_baseline,
        test_immutability_target_runs_the_checker,
        test_static_gate_includes_the_immutability_check,
        test_preflight_job_runs_the_static_gate,
        test_permissions_stay_read_only,
        test_public_api_check_is_its_own_step,
        test_regeneration_runs_only_on_public_api_failure,
        test_artifact_is_published_only_on_public_api_failure,
    ]
    for test in tests:
        test()
    print(f"ci workflow baseline artifact tests passed ({len(tests)} tests)")
