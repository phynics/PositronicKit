#!/usr/bin/env python3
"""Migrate package-internal TurnEngine calls to TurnExecutionRequest.

The rewrite is deliberately narrow: it only touches the three TurnEngine behavioral test files and
only calls on variables named `engine` or `reloadEngine`. Run with `--check` to enforce that no
flattened calls remain.
"""

from __future__ import annotations

import argparse
from pathlib import Path
import re
import sys


ROOT = Path(__file__).resolve().parents[1]
TEST_FILES = (
    ROOT / "Tests/PositronicKitTests/TurnEngineTests.swift",
    ROOT / "Tests/PositronicKitTests/TurnEngineTerminalEventTests.swift",
    ROOT / "Tests/PositronicKitTests/TurnEngineFailurePersistenceTests.swift",
)
CALL = re.compile(r"\b(?:engine|reloadEngine)\.execute\(")
SOURCE_GUARDS = (
    (
        ROOT / "Sources/PositronicKit/Services/Turn/TurnEngine.swift",
        re.compile(r"func\s+(?:execute|startExecution)\(\s*threadID\s*:", re.DOTALL),
        "TurnEngine exposes a flattened execution interface",
    ),
    (
        ROOT / "Sources/PositronicKit/Services/Turn/TurnEngine+TurnPreparation.swift",
        re.compile(r"func\s+prepareSession\(\s*threadID\s*:", re.DOTALL),
        "Turn preparation exposes a flattened request interface",
    ),
    (
        ROOT / "Sources/PositronicKit/PositronicKit.swift",
        re.compile(r"turnEngine\.(?:execute|startExecution)\(\s*threadID\s*:", re.DOTALL),
        "the facade flattens TurnRequest before execution",
    ),
)

REQUEST_LABELS = {
    "threadID": "threadID",
    "requestId": "requestID",
    "message": "message",
    "messageContent": "content",
    "tools": "tools",
    "toolOutputs": "toolOutputs",
    "systemInstructions": "systemInstructions",
    "maxModelRounds": "maxModelRounds",
    "generationParameters": "generationParameters",
    "structuredOutput": "structuredOutput",
    "sidecars": "sidecars",
    "sidecarCommitPolicy": "sidecarCommitPolicy",
    "includeSidecarMechanismPreamble": "includeSidecarMechanismPreamble",
    "assemblyLogger": "promptAssemblyLogger",
    "responseModalities": "responseModalities",
    "audioOutput": "audioOutput",
}
CONTEXT_LABELS = {
    "agentId": "agentID",
    "executionKind": "executionKind",
    "contributors": "contributors",
}


def matching_paren(source: str, opening: int) -> int:
    depth = 0
    quote: str | None = None
    escaped = False
    index = opening
    while index < len(source):
        char = source[index]
        if quote:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == quote:
                quote = None
        elif source.startswith("//", index):
            newline = source.find("\n", index)
            index = len(source) if newline == -1 else newline
            continue
        elif source.startswith("/*", index):
            closing = source.find("*/", index + 2)
            if closing == -1:
                raise ValueError("unterminated block comment")
            index = closing + 2
            continue
        elif char in {'"', "'"}:
            quote = char
        elif char == "(":
            depth += 1
        elif char == ")":
            depth -= 1
            if depth == 0:
                return index
        index += 1
    raise ValueError("unterminated call")


def split_arguments(arguments: str) -> list[str]:
    parts: list[str] = []
    start = 0
    depths = {"(": 0, "[": 0, "{": 0}
    closing = {")": "(", "]": "[", "}": "{"}
    quote: str | None = None
    escaped = False
    index = 0
    while index < len(arguments):
        char = arguments[index]
        if quote:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == quote:
                quote = None
        elif arguments.startswith("//", index):
            newline = arguments.find("\n", index)
            index = len(arguments) if newline == -1 else newline
            continue
        elif arguments.startswith("/*", index):
            end = arguments.find("*/", index + 2)
            if end == -1:
                raise ValueError("unterminated block comment")
            index = end + 2
            continue
        elif char in {'"', "'"}:
            quote = char
        elif char in depths:
            depths[char] += 1
        elif char in closing:
            depths[closing[char]] -= 1
        elif char == "," and not any(depths.values()):
            parts.append(arguments[start:index].strip())
            start = index + 1
        index += 1
    tail = arguments[start:].strip()
    if tail:
        parts.append(tail)
    return parts


def labelled(argument: str) -> tuple[str, str]:
    match = re.match(r"([A-Za-z_][A-Za-z0-9_]*)\s*:\s*(.*)\Z", argument, re.DOTALL)
    if not match:
        raise ValueError(f"expected a labelled argument, got: {argument[:80]!r}")
    return match.group(1), match.group(2).strip()


def indent_value(value: str, prefix: str) -> str:
    lines = value.splitlines()
    return ("\n" + prefix).join(lines)


def replacement(source: str, call_start: int, opening: int, closing: int) -> str | None:
    raw = source[opening + 1 : closing]
    if raw.lstrip().startswith("TurnExecutionRequest("):
        return None
    arguments = [labelled(item) for item in split_arguments(raw)]
    if not arguments or arguments[0][0] not in REQUEST_LABELS:
        return None

    line_start = source.rfind("\n", 0, call_start) + 1
    base = re.match(r"[ \t]*", source[line_start:call_start]).group(0)
    request_indent = base + "        "
    context_indent = base + "    "

    request_arguments: list[tuple[str, str]] = []
    context_arguments: list[tuple[str, str]] = []
    for label, value in arguments:
        if label in REQUEST_LABELS:
            request_arguments.append((REQUEST_LABELS[label], value))
        elif label in CONTEXT_LABELS:
            context_arguments.append((CONTEXT_LABELS[label], value))
        else:
            raise ValueError(f"unsupported TurnEngine.execute argument: {label}")

    labels = {label for label, _ in request_arguments}
    if "threadID" not in labels or "tools" not in labels or not ({"message", "content"} & labels):
        raise ValueError(f"incomplete Turn request at offset {call_start}")

    request_lines = [
        f"{request_indent}{label}: {indent_value(value, request_indent)},"
        for label, value in request_arguments
    ]
    context_lines = [
        f"{context_indent}{label}: {indent_value(value, context_indent)},"
        for label, value in context_arguments
    ]
    if request_lines:
        request_lines[-1] = request_lines[-1].removesuffix(",")
    if context_lines:
        context_lines[-1] = context_lines[-1].removesuffix(",")

    method = source[call_start:opening]
    lines = [f"{method}(TurnExecutionRequest(", f"{context_indent}TurnRequest("]
    lines.extend(request_lines)
    lines.append(f"{context_indent})" + ("," if context_lines else ""))
    lines.extend(context_lines)
    lines.append(f"{base}))")
    return "\n".join(lines)


def migrate(path: Path, check: bool) -> int:
    source = path.read_text()
    edits: list[tuple[int, int, str]] = []
    for match in CALL.finditer(source):
        opening = match.end() - 1
        closing = matching_paren(source, opening)
        rewritten = replacement(source, match.start(), opening, closing)
        if rewritten is not None:
            edits.append((match.start(), closing + 1, rewritten))

    if not edits:
        return 0
    if check:
        print(f"{path.relative_to(ROOT)}: {len(edits)} flattened TurnEngine call(s) remain", file=sys.stderr)
        return len(edits)

    for start, end, rewritten in reversed(edits):
        source = source[:start] + rewritten + source[end:]
    path.write_text(source)
    print(f"migrated {len(edits)} call(s) in {path.relative_to(ROOT)}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    failures = sum(migrate(path, args.check) for path in TEST_FILES)
    if args.check:
        for path, pattern, message in SOURCE_GUARDS:
            if pattern.search(path.read_text()):
                print(f"{path.relative_to(ROOT)}: {message}", file=sys.stderr)
                failures += 1
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
