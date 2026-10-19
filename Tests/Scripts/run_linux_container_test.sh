#!/usr/bin/env bash
set -euo pipefail

test_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$test_dir/../.." && pwd)"
runner="$repo_root/Scripts/run-linux-container.sh"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
export AGENT_LOG_DIR="$tmp_dir/logs"
export AGENT_METADATA_DIR="$tmp_dir/metadata"
export AGENT_SCRATCH_ROOT="$tmp_dir/scratch"
export AGENT_SLOT_DIR="$tmp_dir/slots"
export RUNTIME_CLEANUP_ARGS_OUT="$tmp_dir/cleanup-args"
export RUNTIME_CONTAINER_STATE_FILE="$tmp_dir/container-state"
export AGENT_MAX_CONCURRENT_RUNS=3
export AGENT_RUN_TIMEOUT=5
export AGENT_IMAGE_BUILD_TIMEOUT=5
export AGENT_LOCK_TIMEOUT=5

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
# `info`, persists the built image fingerprint, and records build/run/cleanup args.
make_fake_runtime() {
  local path="$1"
  local version="$2"

  printf '%s\n' '#!/usr/bin/env bash' \
    'case "${1:-}" in' \
    "  --version) printf '%s\\n' '$version' ;;" \
    '  info) exit 0 ;;' \
    '  image)' \
    '    if [ "${2:-}" = inspect ] && [ -f "${RUNTIME_IMAGE_FINGERPRINT_FILE:-}" ]; then' \
    '      cat "$RUNTIME_IMAGE_FINGERPRINT_FILE"' \
    '    else' \
    '      exit 1' \
    '    fi ;;' \
    '  inspect)' \
    '    while [ "$#" -gt 1 ]; do shift; done' \
    '    requested="$1"' \
    '    while IFS="|" read -r stored_name stored_run stored_worktree stored_token; do' \
    '      if [ "$stored_name" = "$requested" ]; then printf "%s %s %s\\n" "$stored_run" "$stored_worktree" "$stored_token"; exit 0; fi' \
    '    done < "${RUNTIME_CONTAINER_STATE_FILE:-/dev/null}"' \
    '    exit 1 ;;' \
    '  build)' \
    '    printf "%s\n" "$@" >> "${RUNTIME_BUILD_ARGS_OUT:-/dev/null}"' \
    '    label=""' \
    '    while [ "$#" -gt 0 ]; do' \
    '      if [ "$1" = --label ]; then label="$2"; shift 2; else shift; fi' \
    '    done' \
    '    printf "%s\n" "${label#*=}" > "${RUNTIME_IMAGE_FINGERPRINT_FILE:-/dev/null}" ;;' \
    '  run)' \
    '    printf "%s\n" "$@" > "$RUNTIME_ARGS_OUT"' \
    '    name="" run_id="" worktree_id="" token=""' \
    '    while [ "$#" -gt 0 ]; do' \
    '      case "$1" in' \
    '        --name) name="$2"; shift 2 ;;' \
    '        --label) case "$2" in org.positronickit.run-id=*) run_id="${2#*=}" ;; org.positronickit.worktree-id=*) worktree_id="${2#*=}" ;; org.positronickit.run-token=*) token="${2#*=}" ;; esac; shift 2 ;;' \
    '        *) shift ;;' \
    '      esac' \
    '    done' \
    '    printf "%s|%s|%s|%s\\n" "$name" "$run_id" "$worktree_id" "$token" >> "${RUNTIME_CONTAINER_STATE_FILE:-/dev/null}"' \
    '    if [ -n "${RUNTIME_RUN_SLEEP:-}" ]; then sleep "$RUNTIME_RUN_SLEEP"; fi' \
    '    exit "${RUNTIME_RUN_EXIT:-0}" ;;' \
    '  rm) printf "%s\n" "$@" >> "${RUNTIME_CLEANUP_ARGS_OUT:-/dev/null}" ;;' \
    'esac' > "$path"
  chmod +x "$path"
}

# A PATH containing only the utilities the runner itself shells out to, so
# runtime auto-detection observes exactly the binaries each case installs.
make_probe_path() {
  local dir="$1"
  local utility

  mkdir -p "$dir"
  for utility in basename cat cut date dirname git head id mkdir mktemp python3 rm sed shasum tee tr uname; do
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
make_probe_path "$empty_probe"

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
fingerprint_file="$tmp_dir/image-fingerprint"
build_probe="$tmp_dir/build-probe-bin"
make_probe_path "$build_probe"
make_fake_runtime "$build_probe/podman" 'podman version 5.0.0'

env -u CONTAINER_RUNTIME -u LINUX_IMAGE PATH="$build_probe" RUNTIME_BUILD_ARGS_OUT="$build_args" \
  RUNTIME_IMAGE_FINGERPRINT_FILE="$fingerprint_file" \
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

# Identical toolchain and Dockerfile content reuse the already-built image.
build_count="$(grep -c '^build$' "$build_args")"
env -u CONTAINER_RUNTIME -u LINUX_IMAGE PATH="$build_probe" RUNTIME_BUILD_ARGS_OUT="$build_args" \
  RUNTIME_IMAGE_FINGERPRINT_FILE="$fingerprint_file" LINUX_SWIFT_VERSION="6.4.0" \
  "$bash_path" "$runner" --build-only
if [ "$(grep -c '^build$' "$build_args")" -ne "$build_count" ]; then
  printf 'FAIL: unchanged Linux image was built again\n' >&2
  exit 1
fi
printf 'ok: reuses an image when the toolchain and Dockerfile are unchanged\n'

# A changed toolchain or system-dependency Dockerfile invalidates the image label.
env -u CONTAINER_RUNTIME -u LINUX_IMAGE PATH="$build_probe" RUNTIME_BUILD_ARGS_OUT="$build_args" \
  RUNTIME_IMAGE_FINGERPRINT_FILE="$fingerprint_file" LINUX_SWIFT_VERSION="6.5.0" \
  "$bash_path" "$runner" --build-only
if [ "$(grep -c '^build$' "$build_args")" -ne "$((build_count + 1))" ]; then
  printf 'FAIL: changed Swift toolchain did not invalidate the Linux image\n' >&2
  exit 1
fi
printf 'ok: rebuilds the image when the Swift toolchain changes\n'

# With no version selected the runner defaults to the current lane, matching the
# Makefile's LINUX_SWIFT_VERSION default.
: > "$build_args"
rm -f "$fingerprint_file"
env -u CONTAINER_RUNTIME -u LINUX_IMAGE -u LINUX_SWIFT_VERSION \
  PATH="$build_probe" RUNTIME_BUILD_ARGS_OUT="$build_args" RUNTIME_IMAGE_FINGERPRINT_FILE="$fingerprint_file" \
  "$bash_path" "$runner" --build-only
if ! grep -Fx -- 'SWIFT_VERSION=6.4.0' "$build_args" >/dev/null; then
  printf 'FAIL: default Swift version was not applied\n' >&2
  exit 1
fi
if ! grep -Fx -- 'positronickit-linux-dev-6.4.0' "$build_args" >/dev/null; then
  printf 'FAIL: default image tag was not derived from the default version\n' >&2
  exit 1
fi
printf 'ok: defaults to the current lane when no Swift version is selected\n'

# --- repository layout handling ---------------------------------------------

linked_repo="$tmp_dir/repository"
linked_worktree="$tmp_dir/worktree"
mkdir -p "$linked_repo/Scripts" "$linked_repo/.devcontainer"
cp "$runner" "$linked_repo/Scripts/run-linux-container.sh"
cp "$(dirname "$runner")/with-agent-resources.py" "$linked_repo/Scripts/with-agent-resources.py"
git -C "$linked_repo" init -q -b main
git -C "$linked_repo" config user.email test@example.invalid
git -C "$linked_repo" config user.name 'Runner Test'
touch "$linked_repo/.devcontainer/Dockerfile"
git -C "$linked_repo" add .devcontainer/Dockerfile Scripts/run-linux-container.sh Scripts/with-agent-resources.py
git -C "$linked_repo" commit -q -m fixture
git -C "$linked_repo" worktree add -q -b linked "$linked_worktree"

fake_runtime="$tmp_dir/capturing-podman"
make_fake_runtime "$fake_runtime" 'podman version 5.0.0'

no_git_bin="$tmp_dir/no-git-bin"
make_probe_path "$no_git_bin"
rm "$no_git_bin/git"
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
  bash "$linked_worktree/Scripts/run-linux-container.sh" --read-only-workspace -- true
common_dir="$(git -C "$linked_worktree" rev-parse --path-format=absolute --git-common-dir)"
if ! grep -Fx "$common_dir:$common_dir:ro,z" "$runtime_args" >/dev/null; then
  printf 'FAIL: linked worktree Git directory was not mounted read-only\n' >&2
  exit 1
fi
if ! grep -Fx "$linked_worktree:/workspace:ro,z" "$runtime_args" >/dev/null; then
  printf 'FAIL: isolated workspace was not mounted read-only\n' >&2
  exit 1
fi
if grep -E '/(var/run/docker.sock|run/podman/podman.sock)' "$runtime_args" >/dev/null; then
  printf 'FAIL: a host container socket was mounted into the test container\n' >&2
  exit 1
fi
printf 'ok: mounts linked worktree Git directory read-only\n'

# A system-dependency change in the Dockerfile invalidates the cached image.
worktree_build_args="$tmp_dir/worktree-build-args"
worktree_fingerprint="$tmp_dir/worktree-fingerprint"
CONTAINER_RUNTIME="$fake_runtime" RUNTIME_BUILD_ARGS_OUT="$worktree_build_args" \
  RUNTIME_IMAGE_FINGERPRINT_FILE="$worktree_fingerprint" \
  bash "$linked_worktree/Scripts/run-linux-container.sh" --build-only
worktree_build_count="$(grep -c '^build$' "$worktree_build_args")"
CONTAINER_RUNTIME="$fake_runtime" RUNTIME_BUILD_ARGS_OUT="$worktree_build_args" \
  RUNTIME_IMAGE_FINGERPRINT_FILE="$worktree_fingerprint" \
  bash "$linked_worktree/Scripts/run-linux-container.sh" --build-only
if [ "$(grep -c '^build$' "$worktree_build_args")" -ne "$worktree_build_count" ]; then
  printf 'FAIL: unchanged worktree image was not reused\n' >&2
  exit 1
fi
printf '# changed system package dependency\n' >> "$linked_worktree/.devcontainer/Dockerfile"
CONTAINER_RUNTIME="$fake_runtime" RUNTIME_BUILD_ARGS_OUT="$worktree_build_args" \
  RUNTIME_IMAGE_FINGERPRINT_FILE="$worktree_fingerprint" \
  bash "$linked_worktree/Scripts/run-linux-container.sh" --build-only
if [ "$(grep -c '^build$' "$worktree_build_args")" -ne "$((worktree_build_count + 1))" ]; then
  printf 'FAIL: Dockerfile dependency change did not invalidate the image\n' >&2
  exit 1
fi
printf 'ok: Dockerfile system-dependency changes invalidate the image\n'

# Isolated runs get distinct scratch, logs, metadata, and named containers.
CONTAINER_RUNTIME="$fake_runtime" RUNTIME_ARGS_OUT="$runtime_args" \
  AGENT_LOG_DIR="$tmp_dir/isolated-logs" AGENT_METADATA_DIR="$tmp_dir/isolated-metadata" \
  HOST_API_TOKEN=do-not-forward-this-value \
  bash "$linked_worktree/Scripts/run-linux-container.sh" --run-id isolated-a \
    --mode isolated --scratch-root "$tmp_dir/isolated-scratch" --read-only-workspace -- true >/dev/null
if grep -F -- 'do-not-forward-this-value' "$runtime_args" >/dev/null; then
  printf 'FAIL: a host credential was forwarded to the agent container\n' >&2
  exit 1
fi
CONTAINER_RUNTIME="$fake_runtime" RUNTIME_ARGS_OUT="$runtime_args" \
  AGENT_LOG_DIR="$tmp_dir/isolated-logs" AGENT_METADATA_DIR="$tmp_dir/isolated-metadata" \
  bash "$linked_worktree/Scripts/run-linux-container.sh" --run-id isolated-b \
    --mode isolated --scratch-root "$tmp_dir/isolated-scratch" --read-only-workspace -- true >/dev/null
python3 - "$tmp_dir/isolated-metadata" "$tmp_dir/isolated-logs" "$tmp_dir/isolated-scratch" <<'PY'
from pathlib import Path
import sys

metadata_root = Path(sys.argv[1])
metadata_files = sorted(metadata_root.glob("**/run.tsv"))
assert len(metadata_files) == 2, metadata_files
records = [dict(line.split("=", 1) for line in path.read_text().splitlines() if "=" in line) for path in metadata_files]
assert {record["run_id"] for record in records} == {"isolated-a", "isolated-b"}, records
assert len({record["scratch_path"] for record in records}) == 2, records
assert len({record["log_path"] for record in records}) == 2, records
assert all(Path(record["log_path"]).is_file() for record in records), records
assert all(record["exit_status"] == "0" for record in records), records
PY
if ! grep -F -- 'isolated-b' "$runtime_args" >/dev/null; then
  printf 'FAIL: container name did not include the run identity\n%s\n' "$runtime_args" >&2
  exit 1
fi
if ! grep -F -- "$tmp_dir/isolated-scratch/" "$runtime_args" | grep -F -- '/isolated-b:/scratch:Z' >/dev/null; then
  printf 'FAIL: isolated scratch path did not include the run identity\n%s\n' "$runtime_args" >&2
  exit 1
fi
if grep -E '/(var/run/docker.sock|run/podman/podman.sock)' "$runtime_args" >/dev/null; then
  printf 'FAIL: container runtime socket was exposed to an agent container\n' >&2
  exit 1
fi
printf 'ok: isolated execution has unique scratch, logs, metadata, and container identity\n'

# A timed-out or failing container client is cleaned up and keeps its exit status.
rm -f "$RUNTIME_CLEANUP_ARGS_OUT"
assert_failure 'enforces the command timeout and stops the run' \
  'command exceeded 0.1s' \
  env CONTAINER_RUNTIME="$fake_runtime" RUNTIME_ARGS_OUT="$runtime_args" \
    RUNTIME_RUN_SLEEP=10 AGENT_SLOT_DIR="$tmp_dir/timeout-slots" \
    bash "$linked_worktree/Scripts/run-linux-container.sh" --timeout 0.1 -- true
if ! grep -Fx -- '--force' "$RUNTIME_CLEANUP_ARGS_OUT" >/dev/null; then
  printf 'FAIL: timed-out container did not receive forced cleanup\n' >&2
  exit 1
fi
set +e
env CONTAINER_RUNTIME="$fake_runtime" RUNTIME_ARGS_OUT="$runtime_args" \
  AGENT_SLOT_DIR="$tmp_dir/failure-slots" RUNTIME_RUN_EXIT=23 \
  bash "$linked_worktree/Scripts/run-linux-container.sh" -- true >/dev/null 2>&1
run_status=$?
set -e
if [ "$run_status" -ne 23 ]; then
  printf 'FAIL: container exit status was changed from 23 to %s\n' "$run_status" >&2
  exit 1
fi
printf 'ok: timeout cleanup and container exit statuses are preserved\n'

# Cancelling the runner also stops the runtime client and removes only its container.
rm -f "$runtime_args" "$RUNTIME_CLEANUP_ARGS_OUT"
env CONTAINER_RUNTIME="$fake_runtime" RUNTIME_ARGS_OUT="$runtime_args" \
  RUNTIME_RUN_SLEEP=10 AGENT_SLOT_DIR="$tmp_dir/cancel-slots" \
  bash "$linked_worktree/Scripts/run-linux-container.sh" --run-id cancel-run -- true \
  > "$tmp_dir/cancel-output" 2>&1 &
cancel_pid=$!
for attempt in {1..100}; do
  if [ -s "$runtime_args" ]; then
    break
  fi
  sleep 0.05
done
if [ ! -s "$runtime_args" ]; then
  printf 'FAIL: cancelled run did not reach the fake container runtime\n' >&2
  kill -TERM "$cancel_pid" 2>/dev/null || true
  wait "$cancel_pid" 2>/dev/null || true
  exit 1
fi
kill -TERM "$cancel_pid"
set +e
wait "$cancel_pid"
cancel_status=$?
set -e
if [ "$cancel_status" -ne 143 ]; then
  printf 'FAIL: runner cancellation returned %s instead of 143\n' "$cancel_status" >&2
  exit 1
fi
if ! grep -Fx -- '--force' "$RUNTIME_CLEANUP_ARGS_OUT" >/dev/null; then
  printf 'FAIL: cancelled container was not cleaned up\n' >&2
  exit 1
fi
printf 'ok: cancellation stops the runtime child and cleans its named container\n'
