#!/usr/bin/env bash
# Saves the Core2's entire 16 MB flash (its current firmware) so it can be
# restored exactly. Reads twice and compares, to catch serial errors.
#   scripts/backup_core2.sh [PORT] [OUT_DIR]     (defaults: /dev/ttyACM0, ./core2-backup)
set -euo pipefail
PORT=${1:-/dev/ttyACM0}
OUT=${2:-core2-backup}
mkdir -p "$OUT"
uvx esptool --port "$PORT" --baud 921600 read-flash 0 0x1000000 "$OUT/core2-full-16MB.bin"
uvx esptool --port "$PORT" --baud 921600 read-flash 0 0x1000000 "$OUT/.verify.bin"
if cmp -s "$OUT/core2-full-16MB.bin" "$OUT/.verify.bin"; then
  rm "$OUT/.verify.bin"
  (cd "$OUT" && sha256sum core2-full-16MB.bin > SHA256SUMS)
  echo "Backup verified: $OUT/core2-full-16MB.bin"
else
  echo "The two reads differ: try a lower baud or another cable." >&2
  exit 1
fi
