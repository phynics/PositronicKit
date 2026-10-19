#!/usr/bin/env python3
"""Build and run a filtered Swift test in the repository's Linux container."""

from __future__ import annotations

import argparse
import os
import re
import shlex
import subprocess
import sys
import time
from pathlib import Path


def positive_int(value: str) -> int:
    parsed = int(value)
    if parsed < 1:
        raise argparse.ArgumentTypeError("must be at least 1")
    return parsed


def record_metadata(path: str | None, key: str, value: str) -> None:
    if path is None:
        return
    destination = Path(path)
    with destination.open("a", encoding="utf-8") as metadata:
        metadata.write(f"{key}={value}\n")


def run_stage(name: str, command: list[str], metadata: str | None) -> int:
    print(f"=== agent-test {name} ===", flush=True)
    print("$ " + shlex.join(command), flush=True)
    started = time.monotonic()
    process = subprocess.Popen(
        command,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        encoding="utf-8",
        errors="replace",
        bufsize=1,
    )
    unmatched_filter = False
    assert process.stdout is not None
    for line in process.stdout:
        sys.stdout.write(line)
        sys.stdout.flush()
        if re.search(r"no matching test cases (?:were|was) (?:run|found)|test run with 0 tests", line, re.I):
            unmatched_filter = True
    status = process.wait()
    if status < 0:
        status = 128 + abs(status)
    elapsed = time.monotonic() - started
    record_metadata(metadata, f"{name}_seconds", f"{elapsed:.3f}")
    record_metadata(metadata, f"{name}_exit_status", str(status))
    if status != 0:
        return status
    if unmatched_filter:
        print("agent-test: FILTER matched no tests", file=sys.stderr)
        return 1
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--filter", required=True)
    parser.add_argument("--traits", default="")
    parser.add_argument("--repetitions", type=positive_int)
    parser.add_argument("--jobs", type=positive_int, default=1)
    parser.add_argument("--scratch-path", required=True)
    parser.add_argument("--metadata")
    args = parser.parse_args()
    if not args.filter.strip():
        parser.error("--filter must not be empty")

    swift_flags = shlex.split(os.environ.get("SWIFT_BUILD_FLAGS", ""))
    compile_command = ["swift", "build", *swift_flags, "--build-tests", "--jobs", str(args.jobs), "--scratch-path", args.scratch_path]
    if args.traits:
        compile_command.extend(["--traits", args.traits])
    compile_status = run_stage("compile", compile_command, args.metadata)
    if compile_status != 0:
        return compile_status

    test_command = ["swift", "test", *swift_flags, "--skip-build", "--jobs", str(args.jobs), "--scratch-path", args.scratch_path]
    if args.traits:
        test_command.extend(["--traits", args.traits])
    if args.repetitions:
        test_command.extend(["--maximum-repetitions", str(args.repetitions)])
    test_command.extend(["--filter", args.filter])
    return run_stage("test", test_command, args.metadata)


if __name__ == "__main__":
    raise SystemExit(main())
