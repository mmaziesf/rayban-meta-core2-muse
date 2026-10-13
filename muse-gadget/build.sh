#!/usr/bin/env bash
# Builds (and optionally flashes) the Muse gadget firmware for an M5Stack
# Core2 v1.1, putting the SDK token, speech server URLs and token, and the
# optional glasses relay URL from .env into the build's sdkconfig (git-ignored)
# without printing them.
#
#   muse-gadget/build.sh [SDK_DIR] [flash]
#
# .env (repo root): GADGET_SDK_TOKEN=mgst_...  TTS_URL=  STT_URL=  [SPEECH_TOKEN=]
#                   [GLASSES_RELAY_URL=http://<pc>:8765/snapshot.jpg]
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
def need(key, pattern, hint, optional=False):
    value = env.get(key, "")
    if not value and optional:
        return ""
    if not re.fullmatch(pattern, value):
        sys.exit(f"{key} in .env is missing or malformed ({hint})")
    return value
url_re = r"https?://[^\s\"]+"
values = {
    "CONFIG_GADGET_SDK_TOKEN": need("GADGET_SDK_TOKEN", r"mgst_[A-Za-z0-9_\-]+", "an mgst_ token"),
    "CONFIG_MUSE_TTS_URL": need("TTS_URL", url_re, "http(s)://<speech server>/tts"),
    "CONFIG_MUSE_STT_URL": need("STT_URL", url_re, "http(s)://<speech server>/stt"),
    "CONFIG_MUSE_SPEECH_TOKEN": need("SPEECH_TOKEN", r"[A-Za-z0-9._~+/=\-]+", "letters, digits, ._~+/=-", True),
    # Empty: frames come only from the iPhone app, found over mDNS.
    "CONFIG_HOMEHUB_GLASSES_CAPTURE_URL": need("GLASSES_RELAY_URL", url_re, "http://<pc>:8765/snapshot.jpg", True),
}
if values["CONFIG_MUSE_SPEECH_TOKEN"] and not (values["CONFIG_MUSE_TTS_URL"].startswith("https://")
                                               and values["CONFIG_MUSE_STT_URL"].startswith("https://")):
    print("warning: SPEECH_TOKEN over plain http:// is readable on the network; use https:// URLs", file=sys.stderr)
cfg = open(cfg_path).read()
for key, value in values.items():
    line = f'{key}="{value}"'
    cfg, n = re.subn(rf"^{key}=.*$", lambda _: line, cfg, flags=re.M)
    if not n:
        cfg += line + "\n"
open(cfg_path, "w").write(cfg)
print("sdkconfig: SDK token, speech server and glasses settings set")
EOF

tools/muse/board.sh build core2v11
if [ "$ACTION" = flash ]; then
  tools/muse/board.sh flash core2v11
fi
