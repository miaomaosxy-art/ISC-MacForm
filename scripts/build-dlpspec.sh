#!/usr/bin/env bash
# Build official DLP Spectrum Library 2.0.3 as arm64 dylib + objects.
# Source is local (gitignored): third_party/DLPSpectrumLibrary/
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/third_party/DLPSpectrumLibrary"
OUT="$ROOT/build/dlpspec"
mkdir -p "$OUT" "$ROOT/build"

need=(
  dlpspec.c dlpspec_scan.c dlpspec_calib.c dlpspec_util.c
  dlpspec_scan_col.c dlpspec_scan_had.c dlpspec_helper.c tpl.c
)
for f in "${need[@]}"; do
  [[ -f "$SRC/$f" ]] || { echo "MISSING $SRC/$f" >&2; exit 1; }
done

OBJS=()
for f in "${need[@]}"; do
  obj="$OUT/${f%.c}.o"
  echo "CC $f"
  clang -c -O2 -g -std=c99 \
    -DTPL_NOLIB \
    -I"$SRC" \
    -o "$obj" "$SRC/$f"
  OBJS+=("$obj")
done

echo "CC dlpspec_bridge.c"
clang -c -O2 -g -std=c99 \
  -I"$SRC" \
  -I"$ROOT/Sources/CDLPSpec/include" \
  -o "$OUT/dlpspec_bridge.o" \
  "$ROOT/Sources/CDLPSpec/dlpspec_bridge.c"

ar rcs "$OUT/libdlpspec.a" "${OBJS[@]}"
clang -dynamiclib -o "$ROOT/build/libdlpspec.dylib" \
  "${OBJS[@]}" "$OUT/dlpspec_bridge.o"

echo "Built:"
file "$ROOT/build/libdlpspec.dylib"
file "$OUT/libdlpspec.a"
