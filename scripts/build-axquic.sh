#!/usr/bin/env bash
# Build Rust/axquic (Axolotty's QUIC link) into Vendor/AxQuic.xcframework.
#
# Runs only when the crate's inputs change (a hash of its sources, lock file, header and vendored
# noq), so the Swift dev loop never waits on cargo. The crate is small; a rebuild is seconds,
# a cold one about a minute.
#
# Usage: scripts/build-axquic.sh [--force]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CRATE="$ROOT/Rust/axquic"
OUT="$ROOT/Vendor/AxQuic.xcframework"
STAMP="$OUT/.axolotty-inputs"
TARGETS=(aarch64-apple-darwin)

inputs="$( (cd "$CRATE" && find Cargo.toml Cargo.lock src include vendor -type f ! -path '*/target/*' -print0 \
  | sort -z | xargs -0 shasum -a 256; shasum -a 256 "$ROOT/scripts/build-axquic.sh" | cut -c1-64) | shasum -a 256 | cut -c1-16)"
if [[ "${1:-}" != "--force" && -f "$STAMP" && "$(cat "$STAMP")" == "$inputs" ]]; then
  echo "AxQuic.xcframework is up to date ($inputs)"
  exit 0
fi

command -v cargo >/dev/null || { echo "error: cargo (rustup) is required to build Rust/axquic" >&2; exit 1; }
for t in "${TARGETS[@]}"; do rustup target list --installed | grep -qx "$t" || rustup target add "$t"; done

ARGS=()
# In a folder of its own: every xcframework's headers land in one include/ beside the others
# (GhosttyVT's module map is at its root).
HDRS="$CRATE/target/headers"
rm -rf "$HDRS" && mkdir -p "$HDRS/AxQuic"
cp "$CRATE/include/axquic.h" "$HDRS/AxQuic/"
cat >"$HDRS/AxQuic/module.modulemap" <<'EOF2'
module AxQuic {
    header "axquic.h"
    export *
}
EOF2
for t in "${TARGETS[@]}"; do
  MACOSX_DEPLOYMENT_TARGET=26.0 cargo build --manifest-path "$CRATE/Cargo.toml" --release --locked --target "$t"
  ARGS+=(-library "$CRATE/target/$t/release/libaxquic.a" -headers "$HDRS")
done
rm -rf "$OUT"
xcodebuild -create-xcframework "${ARGS[@]}" -output "$OUT" >/dev/null
echo "$inputs" >"$STAMP"
echo "AxQuic.xcframework built ($inputs)"
