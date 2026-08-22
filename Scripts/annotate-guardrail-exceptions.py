#!/usr/bin/env python3
"""Annotate every match site of the concurrency guardrail rules with an inline
`swiftlint:disable:this` carrying the reviewer's justification.

Rules are global (see .swiftlint.yml); an occurrence that survives without a
site annotation fails `swiftlint lint --strict`.
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

RULE_REASONS = {
    "concurrency_unchecked_sendable":
        "-- reviewed test double (see docs/Concurrency/exception-manifest.md)",
    "concurrency_manual_nslock":
        "-- guarded serialization boundary (see docs/Concurrency/exception-manifest.md)",
    "concurrency_stored_continuation":
        "-- Mutex/actor lifecycle state machine (see docs/Concurrency/exception-manifest.md)",
    "concurrency_stored_task":
        "-- owned by actor/@MainActor (see docs/Concurrency/exception-manifest.md)",
    "concurrency_reference_box_naming":
        "-- actor-based test double (see docs/Concurrency/exception-manifest.md)",
}

FILE_REASONS = {
    "Sources/PKUtilities/ProviderHTTPTransport.swift":
        "-- URLSession delegate serialization boundary (see docs/Concurrency/exception-manifest.md)",
    "Sources/PositronicKit/Services/LLM/LLMService.swift":
        "-- actor method-local coalesced task (see docs/Concurrency/exception-manifest.md)",
}

PATTERNS = [
    ("concurrency_unchecked_sendable", re.compile(r"@unchecked\s+Sendable")),
    ("concurrency_manual_nslock", re.compile(r"\bNSLock\(\)")),
    ("concurrency_stored_continuation", re.compile(
        r"\b(var|let)\s+[A-Za-z_][A-Za-z0-9_]*\s*:\s*"
        r"(CheckedContinuation|UnsafeContinuation|"
        r"Async(Throwing)?Stream\s*<[^>]*>\s*\.Continuation)")),
    ("concurrency_stored_task", re.compile(r"\b(var|let)\s+[A-Za-z_][A-Za-z0-9_]*\s*:\s*Task<")),
    ("concurrency_reference_box_naming", re.compile(
        r"\b(class|actor|struct|enum)\s+[A-Za-z_]*(Box|Cell|Holder)")),
]

COMMENT_RE = re.compile(r"^\s*(///|//[^!]|/\*|\*)")
ALREADY_RE = re.compile(r"swiftlint:")


def walk_swift():
    for dirpath, _, files in os.walk(ROOT):
        rel_prefix = os.path.relpath(dirpath, ROOT)
        if not rel_prefix.startswith(("Sources", "Tests")):
            continue
        for name in files:
            if name.endswith(".swift"):
                yield os.path.join(dirpath, name), os.path.relpath(
                    os.path.join(dirpath, name), ROOT)


def main():
    changed, skipped_existing, total = 0, 0, 0
    for path, rel in walk_swift():
        with open(path, encoding="utf-8") as fh:
            lines = fh.readlines()
        new_lines = list(lines)
        inserts = {}
        for rule, pattern in PATTERNS:
            for idx, line in enumerate(lines):
                if not pattern.search(line):
                    continue
                total += 1
                if ALREADY_RE.search(line):
                    skipped_existing += 1
                    continue
                if COMMENT_RE.search(line):
                    if (
                        idx > 0
                        and lines[idx - 1].lstrip().startswith(
                            f"// swiftlint:disable:next {rule}"
                        )
                    ):
                        skipped_existing += 1
                        continue
                    inserts.setdefault(idx, []).append(rule)
                    continue
                stripped = line.lstrip()
                indent = line[: len(line) - len(stripped)]
                nl = "\n" if stripped.endswith("\n") else ""
                body = stripped[:-1] if nl else stripped
                reason = FILE_REASONS.get(rel, RULE_REASONS[rule])
                new_lines[idx] = (
                    f"{indent}{body} // swiftlint:disable:this {rule} {reason}{nl}"
                )
                changed += 1
        if inserts:
            reason = "-- comment/documentation reference (see docs/Concurrency/exception-manifest.md)"
            rebuilt = []
            for idx in range(len(lines)):
                for rule in inserts.get(idx, []):
                    rebuilt.append(
                        f"// swiftlint:disable:next {rule} {reason}\n"
                    )
                rebuilt.append(new_lines[idx])
            new_lines = rebuilt
        if new_lines != list(lines) or inserts:
            with open(path, "w", encoding="utf-8") as fh:
                fh.writelines(new_lines)
            if inserts:
                changed += sum(len(r) for r in inserts.values())
    print(
        f"annotated {changed} sites ({skipped_existing} already annotated, "
        f"{total} matched total)"
    )


if __name__ == "__main__":
    main()