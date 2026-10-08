#!/usr/bin/env python3
"""Fail when a release-named public API baseline no longer matches its tag.

`api/next-public-api-<platform>.json` tracks `main` and is rewritten on every
reviewed API change. Each `api/<major>.<minor>-public-api-<platform>.json` file
is frozen at the release it names, so its inventory must stay byte-identical to
the blob in the annotated `<major>.<minor>.0` tag. Editing a frozen file instead
of promoting a new Next release hides what changed since the last tag and
breaks the semver comparison, so it fails here.
"""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
API = ROOT / "api"
RELEASE_BASELINE = re.compile(
    r"^(?P<release>\d+\.\d+)-public-api-(?P<platform>linux|macos)\.json$"
)


def git(*arguments: str) -> tuple[int, bytes]:
    result = subprocess.run(
        ("git", *arguments),
        cwd=ROOT,
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    return result.returncode, result.stdout


def release_tag(release: str) -> str:
    return f"{release}.0"


def check() -> int:
    failures: list[str] = []
    checked = 0
    for path in sorted(API.glob("*.json")):
        match = RELEASE_BASELINE.match(path.name)
        if match is None:
            continue
        release = match.group("release")
        tag = release_tag(release)
        tag_status, _ = git("rev-parse", "-q", "--verify", f"refs/tags/{tag}")
        if tag_status != 0:
            print(f"skipping {path.name}: tag {tag} is not present", file=sys.stderr)
            continue
        relative = path.relative_to(ROOT).as_posix()
        blob_status, tagged = git("show", f"{tag}:{relative}")
        if blob_status != 0:
            failures.append(f"{relative} is not present in tag {tag}")
            continue
        checked += 1
        if tagged != path.read_bytes():
            failures.append(f"{relative} differs from tag {tag}")
    if failures:
        print("release public API baselines must equal their release tag:", file=sys.stderr)
        for failure in failures:
            print(f"- {failure}", file=sys.stderr)
        print(
            "Promote new Next graphs with Scripts/promote-public-api-baselines.py; "
            "never edit a frozen file.",
            file=sys.stderr,
        )
        return 1
    print(f"release public API baselines match their tags ({checked} files)")
    return 0


if __name__ == "__main__":
    raise SystemExit(check())
