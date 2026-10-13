# Troubleshooting

Every problem below actually happened while building this project.

## Glasses / DAT

| Symptom | Cause | Fix |
|---|---|---|
| "The app on your glasses needs an update…" and Meta AI shows no update | The SDK expects a newer DAT component on the glasses than they have | Update the glasses (rollouts are staged), or use the SDK version that matches them (this app pins 1.0.0) |
| `Device unavailable` / `Session ended by device` within ~0.3 s, while the device reports `connected` and `compatible` | Known Meta-side lockout ([DAT iOS #292](https://github.com/facebook/meta-wearables-dat-ios/issues/292)), or an SDK older than the glasses' DAT | Turn the glasses off with the **power switch** and on again; toggle Developer Mode off and on in Meta AI; unregister and register the app again; check the SDK version |
| The stream pauses when the phone locks | DAT's `.raw` codec pauses in the background ([#55](https://github.com/facebook/meta-wearables-dat-ios/issues/55)) | Use HEVC: "Keep streaming when phone is locked", the default |
| The glasses play a sound and nothing streams | The glasses refused the session; the reason is in the app's Problem section and the PC log | See the rows above |
| The app shows "PC link disconnected" | The app closes the link when the glasses refuse a session | Read the Problem section; the link itself is usually fine |

## iOS build (xtool on Linux)

| Symptom | Fix |
|---|---|
| `Can't parse BundleExecute file! …/MWDATCamera` | SwiftPM checkouts are read-only, so make them writable before signing (`ios/install.sh` does this) |
| `NIOPosix … epoll_ctl … Operation not permitted` | xtool was run with stdin from `/dev/null`; run it in a terminal, or give it a pipe (`install.sh`) |
| `The following certificates must be revoked` | Free accounts have a certificate limit. Revoking is safe, but other machines using that certificate must re-sign their apps |
| `There are no current IOS devices on this team matching…` | The device was only just registered; rerun |
| `DebugserverClient.Error.unknown` on launch | Launching from the PC isn't supported on iOS 27; tap the app icon |
| The install hangs at `Verifying` | The phone locked; keep it unlocked during installs |

## Core2

| Symptom | Fix |
|---|---|
| `/dev/ttyACM0` permission denied | `sudo usermod -aG dialout $USER` and log in again (or `sg dialout -c "…"` for now) |
| The Muse firmware says the Core2 isn't supported, or the screen stays dark | It's a v1.1: build the `core2v11` profile (this repo's patches), not `core2` |
| `glasses.capture` fails with "not streaming" | The relay hasn't had a frame in 5 s; start the stream in the app |
| `glasses.capture` fails with "not reachable" | No phone was found and `GLASSES_RELAY_URL` is wrong, or a firewall blocks port 8765 |
| The standalone firmware shows nothing | Frames over 15 KB get dropped; the relay keeps them under 14 KB. Check `RELAY_HOST` in `secrets.h` |
| The Core2 can't join Wi-Fi | It's 2.4 GHz only; check the router broadcasts 2.4 GHz |
| Log says `no Glasses Bridge app found on the network` | The app's frame server may have failed (the app logs `Core2 server failed`; current versions restart it with back-off, and on Start or when you return to the app). Otherwise the app isn't open, or iOS **Local Network** access is off for it (Settings → Privacy & Security → Local Network). Check with `avahi-browse -rt _glasses-bridge._tcp`. Phone and Core2 must be on the same network, with no client isolation |
| The avatar freezes or animates choppily, while voice still works | Internal RAM is short: the display's SPI transfers need DMA-capable internal RAM. Watch the heartbeat log line, `int=…K/… dma=…K/…`: when idle, about 49 KB internal and 29 KB DMA is healthy on the Core2 v1.1. Anything kept alive between turns (connections, tasks, buffers under 4 KB, which always go to internal RAM) eats into it. Patches 0003/0004 free the speech connections and mDNS after use for this reason |
| The Core2 acts by itself (talk button presses, test MP3s) while a log reader is open | The serial port has echo on: the log is echoed back into the console, which takes letters as bench commands. Use `stty -F /dev/ttyACM0 raw -echo` (or a raw-mode reader) |

## Voice

| Symptom | Fix |
|---|---|
| "voice pipeline unavailable" after enabling the wake word | Internal RAM is exhausted: the wake word's tensor arena must be in PSRAM (patch 0003 does this) |
| One "Hey Jarvis" triggers several turns | The streaming model's state must be reset at every turn (patch 0003 does this) |
| Replies sound metallic or robotic | Serve 16 kHz audio (the Core2's resampler has no anti-aliasing); `speech_server.py` does by default |
| Replies too quiet | `--loudness` (default −9 dBFS RMS, with a limiter) is the loudest that stays clear on the Core2: at −6 and −3 the limiter and its small speaker cost words. Beyond that, put the Core2 closer to the listener. The Core2's volume setting doesn't scale the speech |
| Muse receives "You" or "Thank you" when nobody spoke | Whisper inventing words for noise; `speech_server.py` drops low-confidence segments and these phantom phrases |
| Muse says the glasses frame is "too blurry" or it "can't make anything out", even for a clear view | Muse doesn't read images from gadget commands, only text: check the Core2 logs `captured … with a description`. If not, the speech server's `/vision` failed: set `MODEL_API_KEY` for it (`[vision]` lines in its log) |
| Muse keeps saying "your glasses aren't streaming" even though they are | After one failed capture Muse may stop calling `glasses.capture` for the rest of the conversation. The Core2 profile's question hint now asks it to call it again every time; with a custom `MUSE_VOICE_NOTE_HINT`, keep that sentence |
| With the phone locked the Core2 gets "no recent frame" but the PC still receives video | iOS invalidated the app's video decoder (`decoder: … failed (OSStatus -12903)` in the app log). Current app versions rebuild it at the next keyframe; update the app |
| A turn ends right after "Hey Jarvis" | Expected only if nothing follows: a transcript that is just the wake word reads as unfinished, so the Core2 waits up to 1.5 s for the question |
| `speech server unreachable` in the log | Check `TTS_URL`/`STT_URL`, that the server runs (`curl <host>/health`) and, for a cloud server, that `SPEECH_TOKEN` matches (the server logs `refused, no valid token`) |
