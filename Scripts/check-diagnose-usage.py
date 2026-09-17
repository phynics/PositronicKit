#!/usr/bin/env python3
"""Enforce the scoped `@diagnose` policy (AGENTS.md, SE-0522).

The build gate runs with `-warnings-as-errors`, so `@diagnose` is a source-level
escape hatch and must stay narrow. Every `@diagnose` in `Sources/` or `Tests/`
must use the reviewed shape:

    @diagnose(<Group>, as: warning, reason: "<why>")

`as: error` is redundant under `-warnings-as-errors` and `as: ignored` deletes
the diagnostic outright; neither is allowed. The `reason:` string names the
migration or deprecation the site serves.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
SCAN_DIRECTORIES = (ROOT / "Sources", ROOT / "Tests")
ATTRIBUTE_START = re.compile(r"@diagnose\s*\(")
REVIEWED_SHAPE = re.compile(
    r"\s*[A-Za-z_][A-Za-z0-9_]*\s*,\s*"
    r"as:\s*warning\s*,\s*"
    r'reason:\s*"[^"\\]+"\s*'
)


def attribute_spans(text: str) -> list[tuple[int, str]]:
    """Return each `@diagnose(...)` as (1-based line, attribute text).

    The scan walks parenthesis depth and skips double-quoted string literals so
    parentheses inside a `reason:` do not end the attribute early.
    """
    spans: list[tuple[int, str]] = []
    for match in ATTRIBUTE_START.finditer(text):
        index = match.end() - 1
        depth = 0
        in_string = False
        escaped = False
        while index < len(text):
            character = text[index]
            if in_string:
                if escaped:
                    escaped = False
                elif character == "\\":
                    escaped = True
                elif character == '"':
                    in_string = False
            elif character == '"':
                in_string = True
            elif character == "(":
                depth += 1
            elif character == ")":
                depth -= 1
                if depth == 0:
                    break
            index += 1
        spans.append((text.count("\n", 0, match.start()) + 1, text[match.start():index + 1]))
    return spans


def main() -> int:
    failures: list[str] = []
    for directory in SCAN_DIRECTORIES:
        if not directory.exists():
            continue
        for path in sorted(directory.rglob("*.swift")):
            for line, attribute in attribute_spans(path.read_text(encoding="utf-8")):
                arguments = attribute[attribute.index("(") + 1:-1]
                if REVIEWED_SHAPE.fullmatch(arguments) is None:
                    failures.append(f"{path.relative_to(ROOT)}:{line}: {attribute.strip()}")
    if failures:
        print(
            'check-diagnose-usage: @diagnose must be '
            '@diagnose(<Group>, as: warning, reason: "<why>"):',
            file=sys.stderr,
        )
        for failure in failures:
            print(f"- {failure}", file=sys.stderr)
        return 1
    print("Diagnose usage scan passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
