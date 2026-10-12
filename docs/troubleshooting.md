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
| `glasses.capture` fails with "not reachable" | `GLASSES_RELAY_URL` is wrong, or a firewall blocks port 8765 |
| The standalone firmware shows nothing | Frames over 15 KB get dropped; the relay keeps them under 14 KB. Check `RELAY_HOST` in `secrets.h` |
| The Core2 can't join Wi-Fi | It's 2.4 GHz only; check the router broadcasts 2.4 GHz |
