#!/usr/bin/env bash
# Build offline interpret_scan tool against libdlpspec.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/third_party/DLPSpectrumLibrary/build"
BIN="$ROOT/build"
mkdir -p "$BIN"

if [[ ! -f "$OUT/libdlpspec.a" && ! -f "$OUT/libdlpspec.dylib" ]]; then
  echo "libdlpspec not built. Run ./scripts/build-dlpspec.sh first." >&2
  exit 1
fi

clang -O2 -g -std=c99 \
  -I"$ROOT/Sources/CDLPSpec/include" \
  -o "$BIN/interpret_scan" \
  "$ROOT/tools/interpret_scan.c" \
  "$ROOT/Sources/CDLPSpec/dlpspec_bridge.c" \
  "$OUT"/dlpspec*.o "$OUT"/tpl*.o \
  -lm

file "$BIN/interpret_scan"
echo "Run: $BIN/interpret_scan scan_complete.bin scan.csv"
