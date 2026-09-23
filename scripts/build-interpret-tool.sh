#!/usr/bin/env bash
# Build offline interpret_scan against locally built DLP Spectrum Library.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/dlpspec"
BIN="$ROOT/build"
mkdir -p "$BIN"

[[ -d "$OUT" ]] || { echo "Run ./scripts/build-dlpspec.sh first" >&2; exit 1; }

# Prefer official headers from third_party (full structs) over recovered stubs.
clang -O2 -g -std=c99 \
  -I"$ROOT/third_party/DLPSpectrumLibrary" \
  -I"$ROOT/Sources/CDLPSpec/include" \
  -o "$BIN/interpret_scan" \
  "$ROOT/tools/interpret_scan.c" \
  "$OUT"/dlpspec*.o "$OUT"/tpl*.o \
  -lm

file "$BIN/interpret_scan"
echo "Run: $BIN/interpret_scan scan_complete.bin scan.csv"
