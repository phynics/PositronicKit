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

assert_failure 'requires Podman without native fallback' \
  'no native Linux fallback is supported' \
  env PODMAN="$tmp_dir/missing-podman" bash "$runner" -- true

fake_podman="$tmp_dir/podman"
printf '%s\n' '#!/usr/bin/env bash' \
  'if [ "${1:-}" = "info" ]; then' \
  '  echo "permission denied by sandbox" >&2' \
  '  exit 1' \
  'fi' > "$fake_podman"
chmod +x "$fake_podman"

assert_failure 'explains Podman sandbox escalation' \
  'rerun the same make command with escalated container-runtime permissions' \
  env PODMAN="$fake_podman" bash "$runner" -- true

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

fake_podman="$tmp_dir/capturing-podman"
podman_args="$tmp_dir/podman-args"
printf '%s\n' '#!/usr/bin/env bash' \
  'case "${1:-}" in' \
  '  info|build) exit 0 ;;' \
  '  run) printf "%s\n" "$@" > "$PODMAN_ARGS_OUT" ;;' \
  'esac' > "$fake_podman"
chmod +x "$fake_podman"

no_git_bin="$tmp_dir/no-git-bin"
mkdir -p "$no_git_bin"
bash_path="$(command -v bash)"
ln -s "$bash_path" "$no_git_bin/bash"
ln -s "$(command -v cat)" "$no_git_bin/cat"
ln -s "$(command -v dirname)" "$no_git_bin/dirname"
ln -s "$(command -v mktemp)" "$no_git_bin/mktemp"
ln -s "$(command -v rm)" "$no_git_bin/rm"
PATH="$no_git_bin" "$bash_path" "$linked_worktree/Scripts/run-linux-container.sh" --help >/dev/null
PODMAN="$fake_podman" PATH="$no_git_bin" \
  "$bash_path" "$linked_worktree/Scripts/run-linux-container.sh" --build-only
printf 'ok: help and image build do not require host Git\n'

PODMAN="$fake_podman" PODMAN_ARGS_OUT="$podman_args" \
  bash "$linked_repo/Scripts/run-linux-container.sh" -- true
plain_common_dir="$(git -C "$linked_repo" rev-parse --path-format=absolute --git-common-dir)"
if grep -Fx "$plain_common_dir:$plain_common_dir:ro,z" "$podman_args" >/dev/null; then
  printf 'FAIL: plain checkout Git directory was mounted separately\n' >&2
  exit 1
fi
printf 'ok: does not mount the Git directory separately for a plain checkout\n'

PODMAN="$fake_podman" PODMAN_ARGS_OUT="$podman_args" \
  bash "$linked_worktree/Scripts/run-linux-container.sh" -- true
common_dir="$(git -C "$linked_worktree" rev-parse --path-format=absolute --git-common-dir)"
if ! grep -Fx "$common_dir:$common_dir:ro,z" "$podman_args" >/dev/null; then
  printf 'FAIL: linked worktree Git directory was not mounted read-only\n' >&2
  exit 1
fi
printf 'ok: mounts linked worktree Git directory read-only\n'
