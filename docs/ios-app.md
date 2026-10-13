# iPhone app: build on Linux with xtool

Glasses Bridge is a small SwiftUI app around Meta's Wearables Device Access
Toolkit (DAT). It registers with the Meta AI app, starts a camera stream from
the glasses, serves the latest frame to the Core2 on your Wi-Fi, and can also
forward the stream to the PC relay. You don't need a Mac:
[xtool](https://github.com/xtool-org/xtool) builds, signs and installs it
from Linux.

Tested with: Ubuntu 26.04, Swift 6.4.0, xtool 1.21.0, Xcode 27.1 RC (its iOS
SDK), DAT iOS SDK 1.0.0, iPhone on iOS 27.2, Ray-Ban Meta glasses.

## 1. One-time toolchain setup

1. **Swift 6.4**, via [swiftly](https://www.swift.org/install/linux/). This
   needs no root, and `-n` leaves your shell profile untouched:
   ```sh
   curl -O https://download.swift.org/swiftly/linux/swiftly-$(uname -m).tar.gz
   tar zxf swiftly-$(uname -m).tar.gz && ./swiftly init -n -y --skip-install
   . ~/.local/share/swiftly/env.sh && swiftly install 6.4.0 --use
   sudo apt-get install binutils-gold gnupg2 libcurl4-openssl-dev libpython3-dev \
     libxml2-dev libncurses-dev libz3-dev zlib1g-dev usbmuxd libimobiledevice-utils
   ```
2. **xtool**: put the [latest AppImage](https://github.com/xtool-org/xtool/releases)
   in `~/.local/bin/xtool` and make it executable.
3. **The iOS SDK.** Download **Xcode 27** (`.xip`) from
   developer.apple.com in your browser. xtool unpacks *all* of Xcode before
   trimming it, so build the SDK on a disk with ~20 GB free and install only
   the trimmed result:
   ```sh
   XTL_TMPDIR=/var/tmp/xtool-work xtool sdk build /var/tmp/Xcode_27.xip /var/tmp/xtool-work
   xtool sdk install /var/tmp/xtool-work/darwin.xtoolsdk     # ~3.4 GB in ~/.swiftpm
   ```
4. **Sign in to Apple** in a real terminal (it asks for a password and 2FA):
   `xtool auth login`. A free Apple ID works: installs expire after 7 days,
   and it allows a few devices and app IDs. A paid account can use an API key.
5. **The iPhone:** connect it over USB, tap *Trust This Computer*, and turn on
   Settings → Privacy & Security → **Developer Mode**.

## 2. Meta side

- Meta AI app → your glasses → **Developer Mode** on (it can switch off after
  firmware updates).
- `Info.plist` uses `MetaAppID = 0`, so no Wearables Developer Center app is
  needed in Developer Mode.

## 3. Configure, build, install

- `ios/xtool.yml`: set `bundleID` to your own reverse-domain ID. xtool
  prefixes it with your team (`XTL-<id>.…`) when signing.
- `ios/Info.plist`: the `MWDAT` keys are already set for Developer Mode.
  `TeamID` may stay empty.

```sh
ios/install.sh     # build + sign + install over USB; keep the phone unlocked
```

`install.sh` works around three xtool problems we hit:
1. **Read-only frameworks.** SwiftPM checks out binary packages read-only,
   and xtool copies that mode into the app, so the signer fails with
   `Can't parse BundleExecute file`. The script makes them writable.
2. **xtool prompts crash on `/dev/null` stdin** (`epoll_ctl … Operation not
   permitted`). The script gives xtool a pipe when it isn't run from a
   terminal.
3. **First install.** xtool may ask to revoke an existing development
   certificate (free accounts have a small limit), and a newly registered
   device can take a moment to show up. Rerun if provisioning fails once.

Launching from the PC (`xtool launch`) doesn't work on iOS 27, so tap the app
icon. The first time, trust the developer in Settings → General → VPN &
Device Management.

## 4. Use

1. **Register with Meta AI**: the app switches to Meta AI and back.
2. **Set up the stream:**
   - Leave **Serve frames to Core2** on.
   - Optionally enter a PC address (`192.168.x.x:8765`) to also stream to
     `pc/viewer.py`. Leave it empty if there's no PC.
   - Pick a resolution (720×1280, 504×896 or 360×640) and a frame rate
     (2–30 fps). Medium at 15 fps is a good default.
   - Leave **Keep streaming when phone is locked** on: this is the HEVC mode.
3. **Start streaming.** Meta AI asks for camera permission once, and iOS asks
   for **Local Network** access: allow it, or the Core2 can't find the phone.
   If you declined, turn it on in Settings → Privacy & Security → Local
   Network → Glasses Bridge.

## Serving frames to the Core2

`SnapshotServer.swift` runs a tiny HTTP server on port **8765**:

- **What it serves.** `GET /snapshot.jpg` returns the newest frame as a JPEG
  (640 px on the long side, quality 0.7), or `503` if no frame has arrived in
  the last 5 s.
- **How the Core2 finds it.** The server is advertised over Bonjour as
  `_glasses-bridge._tcp` (listed in `NSBonjourServices` in `Info.plist`).
- **Locked phone.** While serving, every HEVC frame is decoded in software,
  even with the phone locked: hardware decoding isn't allowed in the
  background. The newest frame is kept as a `CIImage`, and JPEG encoding
  happens only when the Core2 asks.
- **Self-repair.** iOS can reset the app's Bonjour connection, for example
  around the Local Network prompt; the server then fails with
  `DefunctConnection`. It restarts on its own after 2 s, backing off to once
  a minute, and also when you tap Start or return to the app.
- **The Status section** shows *Core2 server: listening on port 8765* and a
  *Core2 frames* counter with the time and address of the last request.

You can check the server from any computer on the network:

```sh
avahi-browse -rt _glasses-bridge._tcp        # or: dns-sd -B _glasses-bridge._tcp
curl -o frame.jpg http://<phone-ip>:8765/snapshot.jpg
```

The app shows a **Problem** section with the exact DAT error. All log lines
also go to the PC, so `pc/viewer.py` prints them.

## Choosing the DAT version

The app pins `meta-wearables-dat-ios` **1.0.0** (`ios/Package.swift`). With
our glasses:

| SDK | Result |
|---|---|
| 1.0.1 | "The app on your glasses needs an update…" before the glasses update was available |
| 0.9.0 | "Device unavailable" / "Session ended by device" |
| 1.0.0 | Streams, once the glasses were updated |

If you see the update error and Meta AI offers no update, update the glasses
firmware and try again later; rollouts are staged.
