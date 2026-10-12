#!/usr/bin/env bash
# Writes a backup made by backup_core2.sh back to the Core2 (all 16 MB).
#   scripts/restore_core2.sh [PORT] [BACKUP_DIR]
set -euo pipefail
PORT=${1:-/dev/ttyACM0}
DIR=${2:-core2-backup}
(cd "$DIR" && sha256sum -c SHA256SUMS)
uvx esptool --port "$PORT" --baud 921600 write-flash 0x0 "$DIR/core2-full-16MB.bin"
