#!/usr/bin/env bash
# Builds (and optionally flashes) the Muse gadget firmware for an M5Stack
# Core2 v1.1, putting the SDK token and glasses relay URL from .env into the
# build's sdkconfig without printing them.
#
#   muse-gadget/build.sh [SDK_DIR] [flash]
#
# .env (repo root): GADGET_SDK_TOKEN=mgst_...   GLASSES_RELAY_URL=http://<pc>:8765/snapshot.jpg
# ESP-IDF v6.0.1: set IDF_EXPORT=/path/to/esp-idf/export.sh if it isn't in
# ~/esp/esp-idf-v6.0.1 or ~/.espressif/esp-idf-v6.0.1.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
SDK=$(cd "${1:-$ROOT/../muse-gadget-sdk}" && pwd)/esp32
ACTION=${2:-build}
PROFILE=m5stack-core2-v11
B=build-muse-$PROFILE

for f in "${IDF_EXPORT:-}" "$HOME/.espressif/esp-idf-v6.0.1/export.sh" "$HOME/esp/esp-idf-v6.0.1/export.sh"; do
  if [ -n "$f" ] && [ -f "$f" ]; then export IDF_EXPORT="$f"; break; fi
done
[ -n "${IDF_EXPORT:-}" ] || { echo "ESP-IDF v6.0.1 not found; set IDF_EXPORT" >&2; exit 1; }
. "$IDF_EXPORT" >/dev/null

cd "$SDK"
if [ ! -f "$B/sdkconfig" ]; then
  # Generate the build's sdkconfig from the board overlays first.
  idf.py -B "$B" -DIDF_TARGET=esp32 -DSDKCONFIG="$B/sdkconfig" \
    -DSDKCONFIG_DEFAULTS="sdkconfig.defaults;devices/sdkconfig.muse;devices/sdkconfig.muse-$PROFILE" \
    reconfigure >/dev/null
fi

python3 - "$ROOT/.env" "$B/sdkconfig" <<'EOF'
import re, sys
env_path, cfg_path = sys.argv[1], sys.argv[2]
env = {}
try:
    for line in open(env_path):
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            key, value = line.split("=", 1)
            env[key.strip()] = value.strip().strip('"').strip("'")
except FileNotFoundError:
    sys.exit(f"{env_path} not found: copy .env.example to .env and fill it in")
token, url = env.get("GADGET_SDK_TOKEN", ""), env.get("GLASSES_RELAY_URL", "")
if not re.fullmatch(r"mgst_[A-Za-z0-9_\-]+", token):
    sys.exit("GADGET_SDK_TOKEN in .env is missing or not an mgst_ token")
if not re.fullmatch(r"http://[^\s\"]+", url):
    sys.exit("GLASSES_RELAY_URL in .env is missing (http://<pc>:8765/snapshot.jpg)")
cfg = open(cfg_path).read()
cfg = re.sub(r'^CONFIG_GADGET_SDK_TOKEN=.*$', f'CONFIG_GADGET_SDK_TOKEN="{token}"', cfg, flags=re.M)
cfg = re.sub(r'^CONFIG_HOMEHUB_GLASSES_CAPTURE_URL=.*$', f'CONFIG_HOMEHUB_GLASSES_CAPTURE_URL="{url}"', cfg, flags=re.M)
open(cfg_path, "w").write(cfg)
print("sdkconfig: SDK token and glasses relay URL set")
EOF

tools/muse/board.sh build core2v11
if [ "$ACTION" = flash ]; then
  tools/muse/board.sh flash core2v11
fi
