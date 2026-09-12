#!/usr/bin/env bash
set -euo pipefail

script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
exec make -C "$script_directory/.." agent-test \
    FILTER='TypedStructuredGenerationTests|StructuredOutputDecoderTests|FacadeOneShotTests'
