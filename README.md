# Ray-Ban Meta × M5Stack Core2 × Muse

See what your Ray-Ban Meta glasses see on an M5Stack Core2, and let your Muse
assistant look through them: hold the Core2's touch strip, ask "what am I
looking at?", and Muse answers on the Core2's screen.

```
 Ray-Ban Meta ──(Meta DAT SDK)──▶ iPhone app ──HEVC/WebSocket──▶ PC relay (pc/viewer.py)
                                  (ios/)                          │  decodes, keeps latest frame
                                                                  │  GET /snapshot.jpg
                                                                  ▼
                                 Muse cloud ◀──Noise session──── M5Stack Core2 v1.1
                                 (your Muse) ──glasses.capture──▶ Muse Gadget firmware
                                                                  (Jollybot UI, push-to-talk)
```

The glasses can't talk to a microcontroller directly: Meta only exposes the
camera to phone apps through the Wearables Device Access Toolkit (DAT). So
an iPhone app receives the stream and forwards it to a small relay on your
computer, and the Core2 (running Meta's open-source Muse Gadget SDK with
the patches here) fetches frames from that relay whenever Muse asks for one.

## What's in here

| Path | What it is |
|---|---|
| [`ios/`](ios) | **Glasses Bridge** iPhone app (SwiftUI + DAT SDK 1.0.0), built **on Linux** with [xtool](https://github.com/xtool-org/xtool). Streams the glasses camera as HEVC, which keeps flowing while the phone is locked. |
| [`pc/`](pc) | **Relay and agent** (Python, run with `uv`). Decodes the stream, shows it, serves `/snapshot.jpg`, relays frames to the standalone Core2 firmware, plus an optional Muse Spark vision agent, local Whisper speech-to-text and a meal log. |
| [`muse-gadget/`](muse-gadget) | **Patches for Meta's [Muse Gadget SDK](https://github.com/facebookincubator/muse-gadget-sdk)**: Core2 **v1.1** (AXP2101) support, which upstream lacks, and a `glasses.capture` command so Muse can see through the glasses. Scripts to apply, build and flash. |
| [`core2-standalone/`](core2-standalone) | Alternative Core2 firmware (Arduino/M5Unified) without Muse: a live glasses video display with push-to-talk to the PC agent. |
| [`scripts/`](scripts) | Back up and restore the Core2's entire flash. |
| [`docs/`](docs) | Detailed guides, listed below. |

## Docs

1. [Architecture and data flow](docs/architecture.md)
2. [iPhone app: build on Linux with xtool](docs/ios-app.md)
3. [PC relay and agent](docs/pc-relay.md)
4. [Core2 + Muse Gadget SDK (v1.1 port, glasses.capture)](docs/core2-muse-gadget.md)
5. [Standalone Core2 firmware](docs/core2-standalone.md)
6. [Meal logging and costs](docs/meal-logging.md)
7. [Troubleshooting](docs/troubleshooting.md): every problem we hit and its fix

## Quick start

You need Ray-Ban Meta glasses (DAT Developer Mode on), an iPhone with the
Meta AI and Muse apps, an **M5Stack Core2 v1.1**, and a Linux PC on the same
Wi-Fi (2.4 GHz for the Core2).

```sh
git clone https://github.com/<you>/rayban-meta-core2-muse && cd rayban-meta-core2-muse
cp .env.example .env            # fill in GADGET_SDK_TOKEN, GLASSES_RELAY_URL (and MODEL_API_KEY for the PC agent)

# 1. Back up the Core2 first (all 16 MB); restore any time with scripts/restore_core2.sh
scripts/backup_core2.sh /dev/ttyACM0

# 2. PC relay (keep it running)
pc/viewer.py

# 3. Muse gadget firmware on the Core2 (needs ESP-IDF v6.0.1)
muse-gadget/setup.sh            # clones Meta's SDK and applies the patches
muse-gadget/build.sh "" flash   # builds with your token/URL from .env and flashes

# 4. iPhone app (needs the xtool setup from docs/ios-app.md)
ios/install.sh
```

Then pair the Core2 in the Muse app (Settings → Devices → Developer mode →
Add Device → `MuseGadget-XXXXXX`, tap the touch strip to confirm), start
streaming in Glasses Bridge, hold the middle of the Core2's touch strip and
ask about what you see.

## Secrets

Nothing secret is committed. All credentials live in `.env` (git-ignored):

- `MODEL_API_KEY`: Meta Model API key, used only by the PC agent.
- `GADGET_SDK_TOKEN`: Muse Gadget SDK token. `muse-gadget/build.sh` writes it
  into the git-ignored build directory, never into source. It ships inside the
  firmware, so treat it as an identifier: revoke and regenerate it on
  gadgets.muse.ai if it leaks.
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
- **xtool on Linux:** it extracts the iOS SDK from your own `Xcode.xip`.
  Whether Apple's license allows the SDK on non-Apple hardware is debated;
  decide for yourself.
- **The Jollybot avatar and Muse are Meta's.** The patches don't include or
  change the avatar.
- **Not affiliated with Meta, M5Stack or Apple.** Flashing custom firmware can
  brick a board: back it up first.

## License

Apache License 2.0, see [LICENSE](LICENSE). The patches in `muse-gadget/`
modify Meta's Muse Gadget SDK (Apache 2.0); the SDK's Jollybot avatar is not
covered by its license and isn't part of this repo.
