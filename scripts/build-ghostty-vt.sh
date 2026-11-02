#!/usr/bin/env bash
# Build libghostty-vt once, at a pinned upstream commit, into Vendor/GhosttyVT.xcframework.
#
# Zig never runs in the inner dev loop: this script runs only when the pin in
# Vendor/ghostty-vt.lock changes (or the xcframework is missing). Sources and the
# Zig cache live in .cache/ghostty-vt (gitignored, deleted after a successful build
# unless KEEP_CACHE=1) so nothing grows without bound.
#
# Usage: scripts/build-ghostty-vt.sh [--force]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOCK="$ROOT/Vendor/ghostty-vt.lock"
OUT="$ROOT/Vendor/GhosttyVT.xcframework"
STAMP="$OUT/.axolotty-commit"
CACHE="$ROOT/.cache/ghostty-vt"

# shellcheck source=/dev/null
source "$LOCK" # GHOSTTY_REPO, GHOSTTY_COMMIT, MACOS_MIN, ZIG_VERSION

if [[ "${1:-}" != "--force" && -f "$STAMP" && "$(cat "$STAMP")" == "$GHOSTTY_COMMIT" ]]; then
  echo "GhosttyVT.xcframework is up to date ($GHOSTTY_COMMIT)"
  exit 0
fi

command -v zig >/dev/null || { echo "error: zig $ZIG_VERSION is required to (re)build libghostty-vt" >&2; exit 1; }
have_zig="$(zig version)"
[[ "$have_zig" == "$ZIG_VERSION"* ]] || echo "warning: zig $have_zig != pinned $ZIG_VERSION" >&2

mkdir -p "$CACHE"
SRC="$CACHE/src"
if [[ ! -d "$SRC/.git" ]]; then
  git init -q "$SRC"
  git -C "$SRC" remote add origin "$GHOSTTY_REPO"
fi
# A local mirror (GHOSTTY_LOCAL=/path/to/ghostty) avoids the network when the commit is already there.
if [[ -n "${GHOSTTY_LOCAL:-}" ]]; then
  git -C "$SRC" fetch -q --depth 1 "$GHOSTTY_LOCAL" "$GHOSTTY_COMMIT"
else
  git -C "$SRC" fetch -q --depth 1 origin "$GHOSTTY_COMMIT"
fi
git -C "$SRC" checkout -q --force FETCH_HEAD

export ZIG_GLOBAL_CACHE_DIR="$CACHE/zig-global"
export ZIG_LOCAL_CACHE_DIR="$CACHE/zig-local"
PREFIX="$CACHE/out"
rm -rf "$PREFIX"

echo "building libghostty-vt $GHOSTTY_COMMIT (ReleaseFast; macOS + iOS + iOS Simulator)…"
(cd "$SRC" && nice -n 10 zig build \
  -Demit-lib-vt=true \
  -Demit-xcframework=true \
  -Doptimize=ReleaseFast \
  --prefix "$PREFIX")

UPSTREAM="$PREFIX/lib/ghostty-vt.xcframework"
[[ -d "$UPSTREAM" ]] || { echo "error: $UPSTREAM missing" >&2; ls -R "$PREFIX" >&2; exit 1; }

# Our own headers + module map so Swift can `import GhosttyVT` on every platform.
HDRS="$CACHE/headers"
rm -rf "$HDRS" && mkdir -p "$HDRS"
cp -R "$PREFIX/include/ghostty" "$HDRS/ghostty"
cat >"$HDRS/module.modulemap" <<'EOF2'
module GhosttyVT {
  header "ghostty/vt.h"
  link "ghostty-vt"
  link "c++"
  export *
}
EOF2

# Re-wrap every upstream slice with those headers. Each static archive is renamed
# libghostty-vt.a so `link "ghostty-vt"` resolves on all platforms.
ARGS=()
SLICES="$CACHE/slices"
rm -rf "$SLICES" && mkdir -p "$SLICES"
while IFS= read -r lib; do
  slice="$(basename "$(dirname "$lib")")"
  mkdir -p "$SLICES/$slice"
  cp "$lib" "$SLICES/$slice/libghostty-vt.a"
  strip -S "$SLICES/$slice/libghostty-vt.a" 2>/dev/null || true
  ARGS+=(-library "$SLICES/$slice/libghostty-vt.a" -headers "$HDRS")
done < <(find "$UPSTREAM" -name '*.a')
[[ ${#ARGS[@]} -gt 0 ]] || { echo "error: no slices in $UPSTREAM" >&2; exit 1; }

rm -rf "$OUT"
xcodebuild -create-xcframework "${ARGS[@]}" -output "$OUT" >/dev/null
echo "$GHOSTTY_COMMIT" >"$STAMP"
(cd "$OUT" && find . -name "*.a" -exec shasum -a 256 {} \;) >"$OUT/.axolotty-sha256"
du -sh "$OUT"

if [[ "${KEEP_CACHE:-0}" != "1" ]]; then
  rm -rf "$CACHE/zig-local" "$CACHE/zig-global" "$PREFIX"
fi
echo "done → $OUT"
