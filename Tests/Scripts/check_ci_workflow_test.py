#!/usr/bin/env python3
"""Static guardrails for CI public API baselines and release gate workflows.

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
RELEASE_WORKFLOW = ROOT / ".github/workflows/release-gate.yml"
SBOM_WORKFLOW = ROOT / ".github/workflows/release-sbom.yml"
NIGHTLY_LIVE = ROOT / ".github/workflows/nightly-live.yml"
NIGHTLY_FLAKE = ROOT / ".github/workflows/nightly-flake-detection.yml"
DEPENDABOT = ROOT / ".github/dependabot.yml"
IOS_SCRIPT = ROOT / "Scripts/run-ios-verify.sh"
MAKEFILE = ROOT / "Makefile"
MACOS_JOB = "macos-verify"
LINUX_JOB = "linux-verify"
IOS_JOB = "ios-verify"
PREFLIGHT_JOB = "preflight"
NEXT_BASELINE_SCRIPT = ROOT / "Scripts/public-api-baseline.py"
IMMUTABILITY_CHECKER = "Scripts/check-public-api-baseline-immutability.py"
PUBLIC_API_OUTCOME_CONDITION = (
    "if: failure() && steps.public-api.outcome == 'failure'"
)
LINUX_OUTCOME_CONDITION = (
    "if: failure() && steps.linux-verify.outcome == 'failure'"
)


def workflow_text() -> str:
    return WORKFLOW.read_text(encoding="utf-8")


def release_workflow_text() -> str:
    return RELEASE_WORKFLOW.read_text(encoding="utf-8")


def sbom_workflow_text() -> str:
    return SBOM_WORKFLOW.read_text(encoding="utf-8")


def nightly_live_text() -> str:
    return NIGHTLY_LIVE.read_text(encoding="utf-8")


def nightly_flake_text() -> str:
    return NIGHTLY_FLAKE.read_text(encoding="utf-8")


def dependabot_text() -> str:
    return DEPENDABOT.read_text(encoding="utf-8")


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


def test_preflight_does_not_require_a_docs_adr_declaration() -> None:
    job = job_block(workflow_text(), PREFLIGHT_JOB)
    assert "check-pr-docs-impact" not in job, job
    assert "Docs / ADR impact" not in job, job


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
    assert "api/next-public-api-macos.json" in job, job
    assert "api/next-experimental-api-macos.json" in job, job
    assert "overwrite: true" in job, job


def test_linux_artifact_publishes_both_baselines() -> None:
    job = job_block(workflow_text(), LINUX_JOB)
    assert "make update-public-api-baseline" in job, job
    assert job.count(LINUX_OUTCOME_CONDITION) >= 2, job
    assert "name: linux-public-api-baseline" in job, job
    assert "if-no-files-found: error" in job, job
    assert "api/next-public-api-linux.json" in job, job
    assert "api/next-experimental-api-linux.json" in job, job
    assert "overwrite: true" in job, job


def test_ios_job_runs_the_shared_ios_gate() -> None:
    job = job_block(workflow_text(), IOS_JOB)
    assert "make verify-ios" in job, job


def test_full_verify_includes_the_ios_gate() -> None:
    block = target_block(makefile_text(), "verify")
    assert "verify-ios" in block, block


def test_ios_gate_runs_the_runner_script() -> None:
    block = target_block(makefile_text(), "verify-ios")
    assert "Scripts/run-ios-verify.sh" in block, block


def test_release_gate_triggers_for_stable_and_rc_tags_and_dispatch() -> None:
    workflow = release_workflow_text()
    assert '- "*.*.*"' in workflow, workflow
    assert '- "*.*.*-rc.*"' in workflow, workflow
    assert "workflow_dispatch:" in workflow, workflow
    assert "tag:" in workflow, workflow
    assert "required: true" in workflow, workflow


def test_release_gate_checks_the_tag_with_full_history_on_both_platforms() -> None:
    workflow = release_workflow_text()
    assert "fetch-depth: 0" in job_block(workflow, "linux-release-gate"), workflow
    assert "fetch-depth: 0" in job_block(workflow, "macos-release-gate"), workflow
    for job_name in ("linux-release-gate", "macos-release-gate"):
        job = job_block(workflow, job_name)
        assert "make verify-public-api-immutability" in job, job
        assert 'make verify-release VERSION="$TAG"' in job, job
        assert 'GITHUB_REF" != "refs/heads/main"' in job, job
    assert "runs-on: ubuntu-24.04" in job_block(workflow, "linux-release-gate"), workflow
    assert "runs-on: xcode-27" in job_block(workflow, "macos-release-gate"), workflow


def test_release_sbom_is_generated_after_both_platform_gates() -> None:
    workflow = release_workflow_text()
    job = job_block(workflow, "release-sbom")
    assert "needs:" in job, job
    assert "- linux-release-gate" in job, job
    assert "- macos-release-gate" in job, job
    assert "Generate the CycloneDX release SBOM" in job, job
    assert "name: release-sbom" in job, job
    assert "if-no-files-found: error" in job, job


def test_release_metadata_pull_requests_run_the_dry_gate_only_when_relevant() -> None:
    workflow = release_workflow_text()
    assert "pull_request:" in workflow, workflow
    assert "- CHANGELOG.md" in workflow, workflow
    assert "- docs/catalog.json" in workflow, workflow
    job = job_block(workflow, "release-metadata-dry-run")
    assert "steps.release-metadata.outputs.changed == 'true'" in job, job
    assert "DRY_RUN=1" in job, job


def test_sbom_upload_requires_a_successful_gate_for_the_same_tag_and_commit() -> None:
    workflow = sbom_workflow_text()
    assert re.search(r"^  actions:\s*read\s*$", workflow, re.MULTILINE), workflow
    assert re.search(r"^  contents:\s*write\s*$", workflow, re.MULTILINE), workflow
    job = job_block(workflow, "attach-sbom")
    assert "actions/workflows/release-gate.yml/runs" in job, job
    assert "Release gate for " in job, job
    assert ".head_sha == env.TAG_SHA" in job, job
    assert "event=workflow_dispatch" in job, job
    assert "branch=main" in job, job
    assert "persist-credentials: false" in job, job
    assert "github.ref == 'refs/heads/main'" in job, job
    assert "gh run download \"$GATE_RUN_ID\" --name release-sbom" in job, job
    assert (
        job.index("Require a successful release gate")
        < job.index("gh run download")
        < job.index("gh release upload")
    ), job


def test_ios_script_builds_every_library_product_for_the_simulator() -> None:
    script = IOS_SCRIPT.read_text(encoding="utf-8")
    assert "Scripts/list-library-products.swift" in script, script
    assert "generic/platform=iOS Simulator" in script, script
    assert "for product in $products" in script, script


def test_nightly_live_is_report_only_and_scheduled() -> None:
    workflow = nightly_live_text()
    assert "schedule:" in workflow, workflow
    assert "workflow_dispatch:" in workflow, workflow
    # Live lanes must never run for a pull request, so a fork can never reach a secret.
    assert "pull_request:" not in workflow, workflow
    assert "push:" not in workflow, workflow
    block = permissions_block(workflow)
    assert re.search(r"^\s+contents:\s*read\s*$", block, re.MULTILINE), block
    assert "write" not in block, block


def test_nightly_live_skips_each_live_job_when_its_secret_is_absent() -> None:
    workflow = nightly_live_text()
    gating = job_block(workflow, "gating")
    assert "outputs:" in gating, gating
    for provider in ("anthropic", "openai", "openrouter"):
        assert f"needs.gating.outputs.{provider} == 'true'" in workflow, workflow
    for job in (
        "live-prompt-cache-anthropic",
        "live-prompt-cache-openai",
        "live-prompt-cache-openrouter",
    ):
        block = job_block(workflow, job)
        assert "needs: gating" in block, block
        assert "continue-on-error: true" in block, block
        assert "--filter Live" in block, block


def test_nightly_live_includes_the_contract_nix_and_downstream_lanes() -> None:
    workflow = nightly_live_text()
    assert "OpenAITransportContract" in job_block(workflow, "openai-contract"), workflow
    assert "nix develop -c make verify-products" in job_block(workflow, "nix-verify-products"), workflow
    for job in ("downstream-gnostic", "downstream-yakamoz"):
        block = job_block(workflow, job)
        assert "continue-on-error: true" in block, block
    # The downstream override points SwiftPM and XcodeGen at this checkout.
    assert ".package(path: " in workflow, workflow
    assert "https://github.com/phynics/Gnostic.git" in workflow, workflow
    assert "https://github.com/phynics/Yakamoz.git" in workflow, workflow


def test_dependabot_groups_actions_and_swift_weekly() -> None:
    text = dependabot_text()
    assert "version: 2" in text, text
    assert 'package-ecosystem: "github-actions"' in text, text
    assert 'package-ecosystem: "swift"' in text, text
    assert text.count('interval: "weekly"') == 2, text
    assert text.count("groups:") == 2, text
    assert "patterns:" in text, text


def test_detect_flakes_run_uses_the_gate_flags() -> None:
    block = target_block(makefile_text(), "detect-flakes-run")
    assert "ITERATIONS is required" in block, block
    assert "$(SWIFT_BUILD_FLAGS)" in block, block
    assert "--xunit-output" in block, block


def test_detect_flakes_run_is_phony() -> None:
    block = target_block(makefile_text(), ".PHONY")
    assert "detect-flakes-run" in block, block


def test_nightly_flake_runs_through_the_make_target() -> None:
    workflow = nightly_flake_text()
    assert "make detect-flakes-run ITERATIONS=" in workflow, workflow
    # The old inline loop ignored $(SWIFT_BUILD_FLAGS); the Make target owns it now.
    assert "swift test --xunit-output" not in workflow, workflow


if __name__ == "__main__":
    tests = [
        test_main_api_check_reads_the_next_baseline,
        test_immutability_target_runs_the_checker,
        test_static_gate_includes_the_immutability_check,
        test_preflight_job_runs_the_static_gate,
        test_preflight_does_not_require_a_docs_adr_declaration,
        test_permissions_stay_read_only,
        test_public_api_check_is_its_own_step,
        test_regeneration_runs_only_on_public_api_failure,
        test_artifact_is_published_only_on_public_api_failure,
        test_linux_artifact_publishes_both_baselines,
        test_ios_job_runs_the_shared_ios_gate,
        test_full_verify_includes_the_ios_gate,
        test_ios_gate_runs_the_runner_script,
        test_ios_script_builds_every_library_product_for_the_simulator,
        test_nightly_live_is_report_only_and_scheduled,
        test_nightly_live_skips_each_live_job_when_its_secret_is_absent,
        test_nightly_live_includes_the_contract_nix_and_downstream_lanes,
        test_dependabot_groups_actions_and_swift_weekly,
        test_detect_flakes_run_uses_the_gate_flags,
        test_detect_flakes_run_is_phony,
        test_nightly_flake_runs_through_the_make_target,
        test_release_gate_triggers_for_stable_and_rc_tags_and_dispatch,
        test_release_gate_checks_the_tag_with_full_history_on_both_platforms,
        test_release_sbom_is_generated_after_both_platform_gates,
        test_release_metadata_pull_requests_run_the_dry_gate_only_when_relevant,
        test_sbom_upload_requires_a_successful_gate_for_the_same_tag_and_commit,
    ]
    for test in tests:
        test()
    print(f"ci workflow baseline artifact tests passed ({len(tests)} tests)")
