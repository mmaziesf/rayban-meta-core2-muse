# Architecture and data flow

## Without a PC

The Core2 can run with no computer at home:

```
 Ray-Ban Meta ──DAT──▶ iPhone: Glasses Bridge ◀── GET /snapshot.jpg ── Core2 (Muse gadget)
                       · decodes every frame       (found over mDNS:      │  ▲
                       · serves the newest         _glasses-bridge._tcp)  │  │ Noise session
                                                                          │  ▼
                                    speech server (cloud, HTTPS) ◀──/stt, /tts──  Muse (cloud)
```

- **Glasses frames** come straight from the phone: see patch 4 in
  [core2-muse-gadget.md](core2-muse-gadget.md) and the app's snapshot
  server in [ios-app.md](ios-app.md).
- **Speech** comes from `pc/speech_server.py`, on any host: see
  [voice.md](voice.md).
- **The PC relay** below is still useful for watching the stream, recording
  it, the Muse Spark agent and meal logging.

## Why there's a phone (and optionally a PC) in the middle

- **The glasses** only share their camera with phone apps, through Meta's
  Wearables Device Access Toolkit (DAT). The link between glasses and phone
  is proprietary and encrypted, so an ESP32 can't join it.
- **The ESP32 in the Core2** has 2.4 GHz Wi-Fi only and no hardware video
  decoder, so it can't decode the glasses' HEVC stream itself.
- **The PC** (or, without one, the phone itself) decodes the stream, keeps the latest frame, and serves it to the
  Core2 and to agents.

## Components

```
┌────────────┐  DAT (BT/Wi-Fi)  ┌──────────────────────┐  ws://pc:8765/ingest   ┌──────────────────────────┐
│ Ray-Ban    │ ───────────────▶ │ iPhone: Glasses      │ ─────────────────────▶ │ PC: pc/viewer.py          │
│ Meta       │                  │ Bridge (ios/)        │  HEVC access units     │  · HEVC decode (PyAV)     │
└────────────┘                  │  · registration      │  (or JPEG)             │  · latest frame           │
                                │  · camera permission │                        │  · window + recording     │
                                │  · .hvc1 passthrough │                        │  · GET /snapshot.jpg      │
                                └──────────────────────┘                        │  · ws /core2 relay        │
                                                                                │  · agent.py (optional)    │
                                                                                └─────┬───────────────┬─────┘
                                                              GET /snapshot.jpg       │               │ ws /core2
                                                              (on glasses.capture)    │               │ (240x280 JPEG)
                                                                                      ▼               ▼
                                 ┌───────────┐   Noise session    ┌──────────────────────┐   ┌───────────────────────┐
                                 │ Muse      │ ◀────────────────▶ │ Core2: Muse Gadget   │   │ Core2: standalone fw   │
                                 │ (cloud)   │  voice notes,      │ firmware + patches   │   │ (core2-standalone/)    │
                                 └───────────┘  commands, replies │ (muse-gadget/)       │   │ video + PC agent       │
                                                                  └──────────────────────┘   └───────────────────────┘
```

The Core2 runs one firmware or the other.

## Protocols

### iPhone → PC (`ws://<pc>:8765/ingest`)

- Text, once: `{"type":"hello","device":…,"resolution":…,"fps":…,"codec":"hevc"|"jpeg"}`
- Text: `{"type":"log","message":…}`, the app's log mirrored to the PC (there's
  no Xcode console when building with xtool).
- Binary: one frame per message. Either a JPEG, or one HEVC access unit in
  Annex B form. HEVC keyframes carry VPS/SPS/PPS, so decoding can start or
  recover at any keyframe.

The app keeps up to 8 HEVC frames in flight. If the network falls further
behind, it skips to the next keyframe rather than sending broken
references. In JPEG mode at most one frame is in flight, and newer frames
replace older ones.

### Phone or PC → Muse gadget (`GET http://<phone or pc>:8765/snapshot.jpg`)

The iPhone app and `pc/viewer.py` serve the same endpoint:

- Returns the latest frame scaled to 640 px on the long side, as
  `image/jpeg` with `Content-Length`.
- Returns `503` when no frame has arrived in the last 5 seconds.

The gadget tries the phone first (found over mDNS), then the PC URL if one is
configured. It fetches a frame when each voice turn starts, so the frame is
ready before Muse asks for it.

The gadget's `glasses.capture` command fetches it, base64-encodes it, and
returns `{"description":…,"format":"jpeg-base64","data_base64":…}`: the SDK's
`camera.capture` shape plus `description`. Muse doesn't look at the image
itself, so `description` comes from the speech server's `/vision`, a vision
model (see [voice.md](voice.md)). Muse decides when to call the command,
based on its description.

### PC ↔ standalone Core2 (`ws://<pc>:8765/core2`)

The Core2 pulls frames: it sends `{"type":"next"}` after drawing each one,
so latency never builds up. The PC centre-crops and resizes each frame to
the size the Core2 announced in `hello`, keeping it under 14 KB because the
Core2's WebSocket library drops messages over 15 KB. Push-to-talk audio goes
up as `audio_start`, then 16-bit PCM chunks, then `audio_end`. Answers come
back as `{"type":"answer"}`.

## Why HEVC

DAT's `.raw` codec delivers decoded frames but **pauses while the app is in
the background or the phone is locked**. `.hvc1` keeps delivering compressed
frames (Meta confirmed this in DAT iOS issue #55). The app forwards them
untouched. The phone decodes them only for its own preview, and only while
the app is visible.
