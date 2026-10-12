# Standalone Core2 firmware (no Muse)

`core2-standalone/` is a small Arduino/[M5Unified](https://github.com/m5stack/M5Unified)
firmware for the Core2 v1.1. It turns the Core2 into a live display for the
glasses, with an agent that runs on the PC instead of Muse.

- **Video:** 240×280 portrait, pulled frame by frame from `pc/viewer.py`.
  That's about 15 fps; the screen shows the actual rate.
- **A (tap):** "What am I looking at?"
- **B (hold):** ask a spoken question. The Core2 records 16 kHz audio into
  PSRAM (up to 15 s), the PC transcribes it with Whisper and asks the agent.
- **C (tap):** log this meal. **C (hold):** undo the last meal.
- **Answers** show in a panel. Tap the screen to close it.

## Build and flash

```sh
uv tool install platformio
cd core2-standalone
cp include/secrets.h.example include/secrets.h   # Wi-Fi (2.4 GHz) and the PC's address
pio run -e core2 -t upload --upload-port /dev/ttyACM0
```

Libraries are pinned in `platformio.ini`: espressif32 7.1.3, M5Unified
0.2.23, WebSockets 2.7.3 and ArduinoJson 7.3.2. Linux needs access to the
serial port: `sudo usermod -aG dialout $USER`, then log in again.

The Core2's WebSocket library (links2004) drops messages over **15 KB**. The
PC therefore re-encodes frames below 14 KB, lowering JPEG quality as needed.
