#!/usr/bin/env bash
# Build official TI DLP Spectrum Library as arm64 libdlpspec.dylib / libdlpspec.a
#
# Expects TI source under third_party/DLPSpectrumLibrary/ (TIDCC49 / TIDCC50).
# Does NOT reimplement dlpspec — only compiles vendor C sources.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/third_party/DLPSpectrumLibrary"
OUT="$ROOT/third_party/DLPSpectrumLibrary/build"
mkdir -p "$OUT"

# Locate source files (TIDCC49 layout varies; search recursively).
find_src() {
  find "$SRC" -name "$1" -type f | head -1
}

need=(
  dlpspec.c dlpspec_scan.c dlpspec_calib.c dlpspec_util.c
  tpl.c dlpspec_scan_col.c dlpspec_scan_had.c dlpspec_helper.c
)

FILES=()
for f in "${need[@]}"; do
  p="$(find_src "$f")"
  if [[ -z "$p" ]]; then
    echo "MISSING source: $f under $SRC" >&2
    echo "Download TIDCC49 (DLP Spectrum Library Installer v2.0.3) from:" >&2
    echo "  https://www.ti.com/tool/download/TIDCC49" >&2
    echo "  https://www.ti.com/tool/download/TIDCC50  (Mac OS v2.0.2)" >&2
    echo "Export approval is required. Extract and copy sources to:" >&2
    echo "  $SRC/" >&2
    exit 1
  fi
  FILES+=("$p")
done

echo "Building ${#FILES[@]} C sources → $OUT/libdlpspec.a + libdlpspec.dylib (arm64)"
OBJS=()
for src in "${FILES[@]}"; do
  obj="$OUT/$(basename "${src%.c}").o"
  # -DTPL_NOLIB if TPL is compiled in-tree (common in TI package).
  clang -c -O2 -g -std=c99 -DTPL_NOLIB \
    -I"$(dirname "$src")" \
    -I"$SRC" \
    -I"$SRC/include" \
    -I"$SRC/src" \
    -o "$obj" "$src"
  OBJS+=("$obj")
done

clang -c -O2 -g -std=c99 -I"$ROOT/Sources/CDLPSpec/include" \
  -o "$OUT/dlpspec_bridge.o" "$ROOT/Sources/CDLPSpec/dlpspec_bridge.c"

ar rcs "$OUT/libdlpspec.a" "${OBJS[@]}"
clang -dynamiclib -o "$OUT/libdlpspec.dylib" "${OBJS[@]}" "$OUT/dlpspec_bridge.o"

echo "Built:"
file "$OUT/libdlpspec.dylib"
file "$OUT/libdlpspec.a"
