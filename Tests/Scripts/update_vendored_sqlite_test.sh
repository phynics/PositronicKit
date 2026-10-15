#!/usr/bin/env bash
# update_vendored_sqlite_test.sh — fail-closed tests for Scripts/update-vendored-sqlite.sh.
#
# The script generates the symbol-prefix header and rewrites the amalgamation.
# A silent change to its parsing could either leave a public `sqlite3_*` symbol
# unprefixed or skip the include entirely. These cases drive the local-source
# path so they never need the network.
set -euo pipefail

test_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$test_dir/../.." && pwd)"
script="$repo_root/Scripts/update-vendored-sqlite.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

pass=0
fail=0

# A minimal amalgamation that matches the real `sqlite3.c` opening markers.
mkdir -p "$tmp_dir/good"
cat > "$tmp_dir/good/sqlite3.h" <<'EOF'
/* A comment mentioning sqlite3_open so the comment stripper is exercised. */
int sqlite3_open(const char *filename);
int sqlite3_close(int handle);
EOF
cat > "$tmp_dir/good/sqlite3.c" <<'EOF'
#ifndef SQLITE_AMALGAMATION
#define SQLITE_CORE 1
#endif
int sqlite3_open(const char *filename) { return 0; }
EOF

if ! bash "$script" --source "$tmp_dir/good" --dest "$tmp_dir/out" > "$tmp_dir/out.log" 2>&1; then
    printf 'FAIL good-fixture: script exited non-zero\n'
    cat "$tmp_dir/out.log"
    fail=$((fail + 1))
else
    if ! grep -q '^#define sqlite3_open pk_sqlite3_open$' "$tmp_dir/out/pk_sqlite_prefix.h"; then
        printf 'FAIL good-fixture: sqlite3_open was not prefixed\n'
        fail=$((fail + 1))
    elif ! grep -q '^#define sqlite3_close pk_sqlite3_close$' "$tmp_dir/out/pk_sqlite_prefix.h"; then
        printf 'FAIL good-fixture: sqlite3_close was not prefixed\n'
        fail=$((fail + 1))
    elif ! grep -q '#include "pk_sqlite_prefix.h"' "$tmp_dir/out/sqlite3.c"; then
        printf 'FAIL good-fixture: prefix include was not injected\n'
        fail=$((fail + 1))
    else
        printf 'ok good-fixture\n'
        pass=$((pass + 1))
    fi
fi

# A `sqlite3.c` without the expected amalgamation markers must fail closed
# rather than write a half-generated directory.
mkdir -p "$tmp_dir/bad"
printf 'int sqlite3_open(const char *filename) { return 0; }\n' > "$tmp_dir/bad/sqlite3.c"
printf 'int sqlite3_open(const char *filename);\n' > "$tmp_dir/bad/sqlite3.h"

if bash "$script" --source "$tmp_dir/bad" --dest "$tmp_dir/bad-out" > "$tmp_dir/bad.log" 2>&1; then
    printf 'FAIL bad-fixture: expected a non-zero exit for a missing marker\n'
    fail=$((fail + 1))
else
    printf 'ok bad-fixture\n'
    pass=$((pass + 1))
fi

printf 'update_vendored_sqlite_test: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
