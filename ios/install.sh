#!/usr/bin/env bash
# Builds, signs and installs Glasses Bridge on the USB-connected iPhone via xtool.
# Free Apple ID installs expire after 7 days; rerun this to refresh.
set -euo pipefail
cd "$(dirname "$0")"
. ~/.local/share/swiftly/env.sh

~/.local/bin/xtool dev build

# SwiftPM checks binary packages out read-only and xtool copies that mode into the
# app bundle, but xtool's signer rewrites binaries in place ("Can't parse BundleExecute file").
chmod -R u+w .build/checkouts/meta-wearables-dat-ios .build/out xtool

# xtool's prompts crash when stdin is /dev/null (non-interactive shells); give it a pipe.
if [ -t 0 ]; then
  ~/.local/bin/xtool dev run
else
  exec 3< <(exec sleep infinity >/dev/null 2>&1)
  holder=$!
  status=0
  ~/.local/bin/xtool dev run <&3 || status=$?
  kill "$holder" 2>/dev/null || true
  exit "$status"
fi
