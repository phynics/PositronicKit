#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

swift test ${SWIFT_BUILD_FLAGS:--Xswiftc -warnings-as-errors} --filter 'RuntimeSetupStoriesTests|ExampleUsageStoriesTests|IntroductoryStoriesTests|PublicRuntimeStoriesTests'
bash "$ROOT/Scripts/validate-docc.sh"
