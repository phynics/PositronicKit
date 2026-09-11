#!/usr/bin/env python3
"""Validate the provider capability manifest and its published Markdown table."""

from __future__ import annotations

import json
import argparse
from pathlib import Path
import re
import sys


ROOT = Path(__file__).resolve().parent.parent
MANIFEST_PATH = ROOT / "Tests/PKTestSupport/Fixtures/ProviderCapabilityMatrix.json"
DOC_PATH = ROOT / "docs/ProviderCapabilityMatrix.md"
REGISTRATION_PATH = ROOT / "Tests/PositronicKitTests/ProviderCapabilityMatrixTests.swift"
PROVIDERS = {"OpenAI", "OpenRouter", "Anthropic", "Ollama", "Foundation Models"}
CAPABILITIES = {"image-input", "audio-input", "audio-output", "mixed-text-image-layout"}
OUTCOMES = {"accepted", "rejected", "disabled"}
REPRESENTATIONS = {
    "ordered-parts",
    "base64-block",
    "typed-audio-delta",
    "ordered-base64-blocks",
    "image-array",
    "provider-specific-rejection",
    "session-factory-not-invoked",
}
PROBES = {"direct-provider", "runtime-ordering"}
ERRORS: list[str] = []


def error(message: str) -> None:
    ERRORS.append(message)


def path_label(path: Path) -> str:
    try:
        return str(path.relative_to(ROOT))
    except ValueError:
        return str(path)


def load_manifest() -> dict:
    try:
        manifest = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        error(f"could not decode {path_label(MANIFEST_PATH)}: {exc}")
        return {}
    if not isinstance(manifest, dict):
        error("provider capability manifest top level must be an object")
        return {}
    return manifest


def validate_cases(manifest: dict) -> set[str]:
    if manifest.get("schemaVersion") != 1:
        error("provider capability manifest schemaVersion must be 1")

    cases = manifest.get("cases")
    if not isinstance(cases, list) or not cases:
        error("provider capability manifest must contain a non-empty cases array")
        return set()

    ids: list[str] = []
    for index, case in enumerate(cases):
        if not isinstance(case, dict):
            error(f"case {index} must be an object")
            continue
        case_id = case.get("id")
        if not isinstance(case_id, str) or not case_id:
            error(f"case {index} must have a non-empty id")
            continue
        ids.append(case_id)
        for field in ("provider", "capability", "expected", "representation", "probe"):
            if not isinstance(case.get(field), str) or not case[field]:
                error(f"case {case_id} must have a non-empty {field}")
        if case.get("provider") not in PROVIDERS:
            error(f"case {case_id} has unknown provider {case.get('provider')!r}")
        if case.get("capability") not in CAPABILITIES:
            error(f"case {case_id} has unknown capability {case.get('capability')!r}")
        if case.get("expected") not in OUTCOMES:
            error(f"case {case_id} has unknown outcome {case.get('expected')!r}")
        if case.get("representation") not in REPRESENTATIONS:
            error(f"case {case_id} has unknown representation {case.get('representation')!r}")
        if case.get("probe") not in PROBES:
            error(f"case {case_id} has unknown probe {case.get('probe')!r}")
        if case.get("expected") == "rejected" and not case.get("expectedError"):
            error(f"rejected case {case_id} must declare expectedError")
        if case.get("expected") == "disabled" and not case.get("expectedError"):
            error(f"disabled case {case_id} must declare expectedError")

    duplicate_ids = sorted({case_id for case_id in ids if ids.count(case_id) > 1})
    for case_id in duplicate_ids:
        error(f"duplicate provider capability case id: {case_id}")
    return set(ids)


def validate_published_table(manifest: dict) -> None:
    published = manifest.get("published")
    headers = published.get("headers") if isinstance(published, dict) else None
    rows = published.get("rows") if isinstance(published, dict) else None
    if headers != ["Provider", "Image input", "Audio input", "Audio output", "Layout notes"]:
        error("manifest published headers do not match the capability matrix contract")
    if not isinstance(rows, list) or {row.get("Provider") for row in rows if isinstance(row, dict)} != PROVIDERS:
        error("manifest published rows must contain exactly the five supported providers")

    try:
        lines = DOC_PATH.read_text(encoding="utf-8").splitlines()
    except OSError as exc:
        error(f"could not read {path_label(DOC_PATH)}: {exc}")
        return
    table_start = next((index for index, line in enumerate(lines) if line.startswith("| Provider |")), None)
    if table_start is None or table_start + 1 >= len(lines):
        error("capability matrix Markdown table is missing")
        return

    def split_row(line: str) -> list[str]:
        return [part.strip() for part in line.strip().strip("|").split("|")]

    actual_headers = split_row(lines[table_start])
    if actual_headers != headers:
        error(f"published Markdown headers differ from manifest: {actual_headers!r}")
        return
    actual_rows: list[dict[str, str]] = []
    for line in lines[table_start + 2 :]:
        if not line.startswith("|"):
            break
        values = split_row(line)
        if len(values) != len(headers):
            error(f"malformed capability matrix row: {line}")
            continue
        actual_rows.append(dict(zip(headers, values)))
    if actual_rows != rows:
        error("published capability Markdown table differs from the manifest")


def validate_registration(case_ids: set[str]) -> None:
    try:
        source = REGISTRATION_PATH.read_text(encoding="utf-8")
    except OSError as exc:
        error(f"could not read executable matrix suite {path_label(REGISTRATION_PATH)}: {exc}")
        return
    match = re.search(r"registeredCaseIDs:\s*Set<String>\s*=\s*\[(?P<body>.*?)\]", source, flags=re.DOTALL)
    if not match:
        error("executable matrix suite must declare registeredCaseIDs")
        return
    registered = set(re.findall(r'"([^"]+)"', match.group("body")))
    if registered != case_ids:
        error(f"manifest cases are not all registered by executable assertions: missing={sorted(case_ids - registered)}, extra={sorted(registered - case_ids)}")


def main(argv: list[str] | None = None) -> int:
    global MANIFEST_PATH, DOC_PATH, REGISTRATION_PATH
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, default=MANIFEST_PATH)
    parser.add_argument("--docs", type=Path, default=DOC_PATH)
    parser.add_argument("--registration", type=Path, default=REGISTRATION_PATH)
    args = parser.parse_args(argv)

    MANIFEST_PATH = args.manifest
    DOC_PATH = args.docs
    REGISTRATION_PATH = args.registration
    ERRORS.clear()

    manifest = load_manifest()
    case_ids = validate_cases(manifest)
    validate_published_table(manifest)
    validate_registration(case_ids)

    if ERRORS:
        print("provider capability matrix validation failed:", file=sys.stderr)
        for item in ERRORS:
            print(f"- {item}", file=sys.stderr)
        return 1

    print(f"provider capability matrix passed ({len(case_ids)} executable cases)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
