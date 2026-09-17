#!/usr/bin/env bash
set -euo pipefail

test_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$test_dir/../.." && pwd)"
runner="$repo_root/Scripts/run-linux-container.sh"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

assert_failure() {
  local name="$1"
  local expected="$2"
  shift 2
  local output
  local status

  set +e
  output="$("$@" 2>&1)"
  status=$?
  set -e

  if [ "$status" -eq 0 ]; then
    printf 'FAIL: %s: expected failure\n%s\n' "$name" "$output" >&2
    exit 1
  fi
  if [[ "$output" != *"$expected"* ]]; then
    printf 'FAIL: %s: expected output to contain %q\n%s\n' \
      "$name" "$expected" "$output" >&2
    exit 1
  fi
  printf 'ok: %s\n' "$name"
}

# Writes a container runtime stub that reports $2 for `--version`, succeeds for
# `info`, records its `build` arguments in $RUNTIME_BUILD_ARGS_OUT and its `run`
# arguments in $RUNTIME_ARGS_OUT.
make_fake_runtime() {
  local path="$1"
  local version="$2"

  printf '%s\n' '#!/usr/bin/env bash' \
    'case "${1:-}" in' \
    "  --version) printf '%s\\n' '$version' ;;" \
    '  info) exit 0 ;;' \
    '  build) printf "%s\n" "$@" > "${RUNTIME_BUILD_ARGS_OUT:-/dev/null}" ;;' \
    '  run) printf "%s\n" "$@" > "$RUNTIME_ARGS_OUT" ;;' \
    'esac' > "$path"
  chmod +x "$path"
}

# A PATH containing only the utilities the runner itself shells out to, so
# runtime auto-detection observes exactly the binaries each case installs.
make_probe_path() {
  local dir="$1"
  local utility

  mkdir -p "$dir"
  for utility in cat dirname git head id mkdir mktemp rm sed; do
    ln -sf "$(command -v "$utility")" "$dir/$utility"
  done
  ln -sf "$(command -v bash)" "$dir/bash"
}

bash_path="$(command -v bash)"
runtime_args="$tmp_dir/runtime-args"

# --- runtime resolution -----------------------------------------------------

assert_failure 'rejects an explicit CONTAINER_RUNTIME that is not executable' \
  'no native Linux fallback is supported' \
  env CONTAINER_RUNTIME="$tmp_dir/missing-runtime" bash "$runner" -- true

empty_probe="$tmp_dir/empty-probe-bin"
mkdir -p "$empty_probe"
ln -sf "$(command -v dirname)" "$empty_probe/dirname"
ln -sf "$(command -v mktemp)" "$empty_probe/mktemp"
ln -sf "$(command -v rm)" "$empty_probe/rm"
ln -sf "$(command -v sed)" "$empty_probe/sed"

assert_failure 'names both supported runtimes when none is available' \
  'requires Podman or Docker' \
  env -u CONTAINER_RUNTIME PATH="$empty_probe" "$bash_path" "$runner" -- true

blocked_runtime="$tmp_dir/blocked-podman"
printf '%s\n' '#!/usr/bin/env bash' \
  'case "${1:-}" in' \
  "  --version) printf '%s\\n' 'podman version 5.0.0' ;;" \
  '  info) echo "permission denied by sandbox" >&2; exit 1 ;;' \
  'esac' > "$blocked_runtime"
chmod +x "$blocked_runtime"

assert_failure 'explains sandbox escalation for an explicit runtime' \
  'rerun the same make command with escalated container-runtime permissions' \
  env CONTAINER_RUNTIME="$blocked_runtime" bash "$runner" -- true

# A blocked Podman with no Docker installed must still surface the escalation
# remediation rather than the generic "no runtime found" message.
blocked_probe="$tmp_dir/blocked-probe-bin"
make_probe_path "$blocked_probe"
cp "$blocked_runtime" "$blocked_probe/podman"
assert_failure 'explains sandbox escalation for a discovered runtime' \
  'rerun the same make command with escalated container-runtime permissions' \
  env -u CONTAINER_RUNTIME PATH="$blocked_probe" "$bash_path" "$runner" -- true

# --- runtime preference and flag selection ----------------------------------

both_probe="$tmp_dir/both-probe-bin"
make_probe_path "$both_probe"
make_fake_runtime "$both_probe/podman" 'podman version 5.0.0'
make_fake_runtime "$both_probe/docker" 'Docker version 29.8.0, build abcdef'

env -u CONTAINER_RUNTIME PATH="$both_probe" RUNTIME_ARGS_OUT="$runtime_args" \
  "$bash_path" "$runner" -- true
if ! grep -Fx -- '--userns=keep-id' "$runtime_args" >/dev/null; then
  printf 'FAIL: Podman run did not receive --userns=keep-id\n' >&2
  exit 1
fi
printf 'ok: prefers Podman when both runtimes are installed\n'

docker_probe="$tmp_dir/docker-probe-bin"
make_probe_path "$docker_probe"
make_fake_runtime "$docker_probe/docker" 'Docker version 29.8.0, build abcdef'

env -u CONTAINER_RUNTIME PATH="$docker_probe" RUNTIME_ARGS_OUT="$runtime_args" \
  "$bash_path" "$runner" -- true
if grep -Fx -- '--userns=keep-id' "$runtime_args" >/dev/null; then
  printf 'FAIL: Docker run received the Podman-only --userns=keep-id flag\n' >&2
  exit 1
fi
if ! grep -Fx -- "$(id -u):$(id -g)" "$runtime_args" >/dev/null; then
  printf 'FAIL: Docker run did not receive the host user mapping\n' >&2
  exit 1
fi
printf 'ok: falls back to Docker and omits the Podman-only user namespace flag\n'

# An explicit override wins over a Podman that is also installed.
override_probe="$tmp_dir/override-probe-bin"
make_probe_path "$override_probe"
make_fake_runtime "$override_probe/podman" 'podman version 5.0.0'
explicit_docker="$tmp_dir/explicit-docker"
make_fake_runtime "$explicit_docker" 'Docker version 29.8.0, build abcdef'

env CONTAINER_RUNTIME="$explicit_docker" PATH="$override_probe" \
  RUNTIME_ARGS_OUT="$runtime_args" "$bash_path" "$runner" -- true
if grep -Fx -- '--userns=keep-id' "$runtime_args" >/dev/null; then
  printf 'FAIL: explicit Docker override was treated as Podman\n' >&2
  exit 1
fi
printf 'ok: CONTAINER_RUNTIME overrides an installed Podman\n'

# --- image toolchain selection ----------------------------------------------

build_args="$tmp_dir/build-args"
build_probe="$tmp_dir/build-probe-bin"
make_probe_path "$build_probe"
make_fake_runtime "$build_probe/podman" 'podman version 5.0.0'

env -u CONTAINER_RUNTIME -u LINUX_IMAGE PATH="$build_probe" RUNTIME_BUILD_ARGS_OUT="$build_args" \
  LINUX_SWIFT_VERSION="6.4.0" \
  "$bash_path" "$runner" --build-only
if ! grep -Fx -- 'SWIFT_VERSION=6.4.0' "$build_args" >/dev/null; then
  printf 'FAIL: image build did not receive the selected Swift version\n' >&2
  exit 1
fi
if ! grep -Fx -- 'positronickit-linux-dev-6.4.0' "$build_args" >/dev/null; then
  printf 'FAIL: image tag was not derived from the selected Swift version\n' >&2
  exit 1
fi
printf 'ok: derives the image tag and build argument from the selected Swift version\n'

# With no version selected the runner defaults to the current lane, matching the
# Makefile's LINUX_SWIFT_VERSION default.
: > "$build_args"
env -u CONTAINER_RUNTIME -u LINUX_IMAGE -u LINUX_SWIFT_VERSION \
  PATH="$build_probe" RUNTIME_BUILD_ARGS_OUT="$build_args" \
  "$bash_path" "$runner" --build-only
if ! grep -Fx -- 'SWIFT_VERSION=6.3.3' "$build_args" >/dev/null; then
  printf 'FAIL: default Swift version was not applied\n' >&2
  exit 1
fi
if ! grep -Fx -- 'positronickit-linux-dev-6.3.3' "$build_args" >/dev/null; then
  printf 'FAIL: default image tag was not derived from the default version\n' >&2
  exit 1
fi
printf 'ok: defaults to the current lane when no Swift version is selected\n'

# --- repository layout handling ---------------------------------------------

linked_repo="$tmp_dir/repository"
linked_worktree="$tmp_dir/worktree"
mkdir -p "$linked_repo/Scripts" "$linked_repo/.devcontainer"
cp "$runner" "$linked_repo/Scripts/run-linux-container.sh"
git -C "$linked_repo" init -q -b main
git -C "$linked_repo" config user.email test@example.invalid
git -C "$linked_repo" config user.name 'Runner Test'
touch "$linked_repo/.devcontainer/Dockerfile"
git -C "$linked_repo" add .devcontainer/Dockerfile Scripts/run-linux-container.sh
git -C "$linked_repo" commit -q -m fixture
git -C "$linked_repo" worktree add -q -b linked "$linked_worktree"

fake_runtime="$tmp_dir/capturing-podman"
make_fake_runtime "$fake_runtime" 'podman version 5.0.0'

no_git_bin="$tmp_dir/no-git-bin"
mkdir -p "$no_git_bin"
ln -s "$bash_path" "$no_git_bin/bash"
ln -s "$(command -v cat)" "$no_git_bin/cat"
ln -s "$(command -v dirname)" "$no_git_bin/dirname"
ln -s "$(command -v head)" "$no_git_bin/head"
ln -s "$(command -v sed)" "$no_git_bin/sed"
ln -s "$(command -v mktemp)" "$no_git_bin/mktemp"
ln -s "$(command -v rm)" "$no_git_bin/rm"
PATH="$no_git_bin" "$bash_path" "$linked_worktree/Scripts/run-linux-container.sh" --help >/dev/null
CONTAINER_RUNTIME="$fake_runtime" PATH="$no_git_bin" \
  "$bash_path" "$linked_worktree/Scripts/run-linux-container.sh" --build-only
printf 'ok: help and image build do not require host Git\n'

CONTAINER_RUNTIME="$fake_runtime" RUNTIME_ARGS_OUT="$runtime_args" \
  bash "$linked_repo/Scripts/run-linux-container.sh" -- true
plain_common_dir="$(git -C "$linked_repo" rev-parse --path-format=absolute --git-common-dir)"
if grep -Fx "$plain_common_dir:$plain_common_dir:ro,z" "$runtime_args" >/dev/null; then
  printf 'FAIL: plain checkout Git directory was mounted separately\n' >&2
  exit 1
fi
printf 'ok: does not mount the Git directory separately for a plain checkout\n'

CONTAINER_RUNTIME="$fake_runtime" RUNTIME_ARGS_OUT="$runtime_args" \
  bash "$linked_worktree/Scripts/run-linux-container.sh" -- true
common_dir="$(git -C "$linked_worktree" rev-parse --path-format=absolute --git-common-dir)"
if ! grep -Fx "$common_dir:$common_dir:ro,z" "$runtime_args" >/dev/null; then
  printf 'FAIL: linked worktree Git directory was not mounted read-only\n' >&2
  exit 1
fi
printf 'ok: mounts linked worktree Git directory read-only\n'
