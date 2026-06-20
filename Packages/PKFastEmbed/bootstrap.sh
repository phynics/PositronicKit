#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix)
      PREFIX="$2"
      shift 2
      ;;
    *)
      echo "unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

if [[ -z "$PREFIX" ]]; then
  echo "usage: $0 --prefix <path>" >&2
  exit 1
fi

RUST_TARGET_DIR="${SCRIPT_DIR}/native/target"
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$RUST_TARGET_DIR}"

pushd "${SCRIPT_DIR}/native" >/dev/null
cargo build --release --locked
popd >/dev/null

mkdir -p "${PREFIX}/lib/pkgconfig" "${PREFIX}/include"
cp "${SCRIPT_DIR}/native/target/release/libpkfastembed.a" "${PREFIX}/lib/"
cp "${SCRIPT_DIR}/native/include/pkfastembed.h" "${PREFIX}/include/"

case "$(uname -s)" in
  Darwin) NATIVE_LIBS="-lc++ -framework Security -framework Foundation" ;;
  Linux) NATIVE_LIBS="-lstdc++ -ldl -lpthread -lm" ;;
  *)
    echo "unsupported host: $(uname -s)" >&2
    exit 1
    ;;
esac

cat > "${PREFIX}/lib/pkgconfig/pkfastembed.pc" <<EOF
prefix=${PREFIX}
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: pkfastembed
Description: PKFastEmbed native bridge for all-MiniLM-L6-v2
Version: 0.1.0
Libs: -L\${libdir} -lpkfastembed ${NATIVE_LIBS}
Cflags: -I\${includedir}
EOF

echo "PKG_CONFIG_PATH=${PREFIX}/lib/pkgconfig"
