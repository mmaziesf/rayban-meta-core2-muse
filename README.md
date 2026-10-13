# Ray-Ban Meta × M5Stack Core2 × Muse

Let your Muse assistant look through your Ray-Ban Meta glasses, with an
M5Stack Core2 as its voice and face: say **"Hey Jarvis, what am I looking
at?"** and the Core2 answers out loud in a friendly, kid-style voice.

```
 Ray-Ban Meta ──(Meta DAT SDK)──▶ iPhone app (ios/) ◀──GET /snapshot.jpg── M5Stack Core2 v1.1
                                  decodes, keeps the       (found by mDNS)   Muse Gadget firmware + patches
                                  newest frame                                · "Hey Jarvis" wake word
                                       │ optional                             · hands-free turns
                                       ▼ HEVC/WebSocket                       · glasses.capture
                                  PC relay (pc/viewer.py)                       │            │
                                  viewer, agent, meal log       speech server ◀─┘ /stt, /tts │ Noise session
                                                                (pc/ or cloud/)              ▼
                                                                                         Muse (cloud)
```

The glasses can't talk to a microcontroller directly: Meta only exposes the
camera to phone apps through the Wearables Device Access Toolkit (DAT). So
an iPhone app receives the stream and keeps the newest frame. The Core2,
running Meta's open-source Muse Gadget SDK with the patches here, finds the
phone on Wi-Fi and fetches a frame as soon as you start talking, so it's
ready when Muse asks to see. A speech server of your own, on a PC or in the
cloud, transcribes you and gives Muse's replies a voice.

## What's in here

| Path | What it is |
|---|---|
| [`ios/`](ios) | **Glasses Bridge** iPhone app (SwiftUI + DAT SDK 1.0.0), built **on Linux** with [xtool](https://github.com/xtool-org/xtool). Streams the glasses camera as HEVC, which keeps flowing while the phone is locked. |
| [`pc/`](pc) | **Speech server and relay** (Python, run with `uv`). `speech_server.py`: Whisper speech-to-text and Kokoro text-to-speech for the Core2. `viewer.py`: decodes and shows the stream, serves `/snapshot.jpg`, relays frames to the standalone Core2 firmware, plus an optional Muse Spark vision agent and a meal log. |
| [`cloud/`](cloud) | A Docker image of the speech server for a cloud host, so the Core2 needs no PC. |
| [`muse-gadget/`](muse-gadget) | **Patches for Meta's [Muse Gadget SDK](https://github.com/facebookincubator/muse-gadget-sdk)**: Core2 **v1.1** (AXP2101) support, which upstream lacks; a `glasses.capture` command so Muse can see through the glasses; an on-device wake word, spoken replies and hands-free turns; frames straight from the phone. Scripts to apply, build and flash. |
| [`core2-standalone/`](core2-standalone) | Alternative Core2 firmware (Arduino/M5Unified) without Muse: a live glasses video display with push-to-talk to the PC agent. |
| [`scripts/`](scripts) | Back up and restore the Core2's entire flash. |
| [`docs/`](docs) | Detailed guides, listed below. |

## Docs

1. [Architecture and data flow](docs/architecture.md)
2. [iPhone app: build on Linux with xtool](docs/ios-app.md)
3. [PC relay and agent](docs/pc-relay.md)
4. [Core2 + Muse Gadget SDK (v1.1 port, glasses.capture, frames from the phone)](docs/core2-muse-gadget.md)
5. [Voice: wake word, speech server, latency, cloud](docs/voice.md)
6. [Standalone Core2 firmware](docs/core2-standalone.md)
7. [Meal logging and costs](docs/meal-logging.md)
8. [Troubleshooting](docs/troubleshooting.md): every problem we hit and its fix

## Quick start

You need Ray-Ban Meta glasses (DAT Developer Mode on), an iPhone with the
Meta AI and Muse apps, an **M5Stack Core2 v1.1**, and a Linux PC to build on.
The phone and the Core2 must share a Wi-Fi network (2.4 GHz for the Core2).

```sh
git clone https://github.com/<you>/rayban-meta-core2-muse && cd rayban-meta-core2-muse
cp .env.example .env            # fill in GADGET_SDK_TOKEN, TTS_URL, STT_URL, MODEL_API_KEY

# 1. Back up the Core2 first (all 16 MB); restore any time with scripts/restore_core2.sh
scripts/backup_core2.sh /dev/ttyACM0

# 2. Speech server (keep it running), on this PC or a cloud host (docs/voice.md)
pc/speech_server.py

# 3. Muse gadget firmware on the Core2 (needs ESP-IDF v6.0.1)
muse-gadget/setup.sh            # clones Meta's SDK and applies the patches
muse-gadget/build.sh "" flash   # builds with your settings from .env and flashes

# 4. iPhone app (needs the xtool setup from docs/ios-app.md)
ios/install.sh

# Optional: PC relay to watch/record the stream, the vision agent and meal logging
pc/viewer.py
```

Then pair the Core2 in the Muse app (Settings → Devices → Developer mode →
Add Device → `MuseGadget-XXXXXX`, tap the touch strip to confirm). Start
streaming in Glasses Bridge (allow Local Network access), and say **"Hey
Jarvis, what am I looking at?"**.

## Secrets

Nothing secret is committed. All credentials live in `.env` (git-ignored):

- `MODEL_API_KEY`: Meta Model API key, used by the PC agent and by the speech
  server's `/vision`. It stays on the server and is never put in the firmware.
- `GADGET_SDK_TOKEN`: Muse Gadget SDK token. `muse-gadget/build.sh` writes it
  into the git-ignored build directory, never into source. It ships inside the
  firmware, so treat it as an identifier: revoke and regenerate it on
  gadgets.muse.ai if it leaks.
- `SPEECH_TOKEN`: shared secret between the Core2 and a speech server on the
  internet (the server's `SPEECH_TOKEN`), sent only over HTTPS. Like the SDK
  token, it ships inside the firmware.
- Wi-Fi credentials for the standalone firmware go in the git-ignored
  `core2-standalone/include/secrets.h`.
- Firmware backups (`core2-backup/`, `*.bin`) are git-ignored: they hold
  vendor firmware and per-device data.

## Status and caveats

- **Tested** on a Core2 v1.1, Ray-Ban Meta glasses, iOS 27, Ubuntu 26.04,
  October 2026.
- **DAT is a developer preview.** The app pins DAT **1.0.0**: with our
  glasses, 1.0.1 asked for a glasses update that Meta AI didn't offer yet,
  and 0.9.0 was refused. See [troubleshooting](docs/troubleshooting.md).
- **Free Apple ID:** the app expires after 7 days; rerun `ios/install.sh`.
- **The wake word is "Hey Jarvis"**, a pre-trained open model. A custom one
  ("Hey Muse") would need training with microWakeWord.
- **Muse doesn't look at images from gadget commands**, only text. So the
  speech server describes each glasses frame with Muse Spark's vision model
  (`MODEL_API_KEY`), and the Core2 passes that description to Muse.
- **Muse's thinking time** (1.5–6 s to start replying) is now most of the
  wait; the gadget's own part is about 1 s ([voice.md](docs/voice.md)).
- **xtool on Linux:** it extracts the iOS SDK from your own `Xcode.xip`.
  Whether Apple's license allows the SDK on non-Apple hardware is debated;
  decide for yourself.
- **The Jollybot avatar and Muse are Meta's.** The patches don't include or
  change the avatar.
- **Third-party models:** the "Hey Jarvis" model (microWakeWord, Apache-2.0)
  ships in patch 0003; Kokoro (Apache-2.0) and Whisper (MIT) models are
  downloaded by the speech server.
- **Not affiliated with Meta, M5Stack or Apple.** Flashing custom firmware can
  brick a board: back it up first.

## License

Apache License 2.0, see [LICENSE](LICENSE). The patches in `muse-gadget/`
modify Meta's Muse Gadget SDK (Apache 2.0); the SDK's Jollybot avatar is not
covered by its license and isn't part of this repo.
