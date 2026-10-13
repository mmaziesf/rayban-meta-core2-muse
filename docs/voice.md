# Voice: wake word, speech server, latency

Out of the box, a Muse gadget sends each press as a voice note and shows
Muse's reply as text. Patch `0003` makes the Core2 a hands-free voice
assistant:

1. **"Hey Jarvis"** wakes it, detected on the Core2 itself.
2. It listens until you stop talking (no button), transcribes you on your
   **speech server**, and sends Muse the text.
3. While Muse thinks, it says a short filler ("Hmm, let me think.").
4. It **speaks** Muse's reply in a bright, kid-friendly voice, sentence by
   sentence as the reply streams in, with captions following the speech.

```
 "Hey Jarvis, what is…"                                     speech server (pc/speech_server.py)
  │ wake word: microWakeWord on the Core2                    ┌──────────────────────────────┐
  ▼                                                          │ /stt  Whisper base.en (int8)  │
 Core2 ── PCM at the first pause ─────────────────────────▶ │ /tts  Kokoro af_bella, +4 st  │
   │  ◀────────────── transcript ─────────────────────────── │       16 kHz MP3, streamed    │
   │── text + style hint ──▶ Muse ── reply text ──▶ Core2 ──▶│                               │
   │  ◀────────────── MP3, sentence by sentence ──────────── └──────────────────────────────┘
   ▼
 speaker + captions
```

## The speech server

`pc/speech_server.py` is a single-file `uv` script (port 8766):

| Endpoint | In | Out |
|---|---|---|
| `POST /stt?rate=16000` | raw 16-bit mono PCM | the transcript, `text/plain` |
| `POST /tts` | reply text, `text/plain` | MP3, chunked, sentence by sentence |
| `GET /health` | | `ok` (no token needed) |

```sh
pc/speech_server.py                          # defaults: --voice af_bella --pitch 4 --tempo 1.05 --loudness -9
SPEECH_TOKEN=... pc/speech_server.py         # require "Authorization: Bearer <token>"
```

Model files: `kokoro-v1.0.onnx` and `voices-v1.0.bin` from
[kokoro-onnx's releases](https://github.com/thewh1teagle/kokoro-onnx/releases)
(`model-files-v1.0`) in `~/.local/share/kokoro`. Whisper downloads itself.

**The voice.** Kokoro's `af_bella` raised **4 semitones**: Kokoro speaks
slower, and one resample raises pitch and formants together. That gives a
toy or cartoon character's voice without the robotic sound of a plain pitch
shift. It's tuned for the Core2's small speaker:

- **No metallic sound.** The output is **16 kHz MP3**. The Core2's own
  resampler is linear with no anti-aliasing, and 24 kHz audio came out
  metallic through it.
- **Loud and clear.** A 180 Hz high-pass (the speaker can't reproduce
  lower), a +2 dB lift at 2.5 kHz, and levelling to −9 dBFS under a soft
  limiter. Each sentence's peaks are capped, so nothing clips.

**Transcription.** Far-field speech arrives quiet (−35 to −45 dBFS), so it
is normalized before Whisper's voice detection runs. Whisper invents words
for noise ("You", "Thank you"), so segments it rates as probably not speech,
and those known phantom phrases, are dropped. A leading "Hey Jarvis" is
removed from the transcript.

**Speed.** Short phrases (the fillers) are cached and synthesized at
startup, so they play at once. On a 16-core desktop, transcribing a question
takes about 0.35 s and the first audio of a reply about 0.3–1.0 s. On 2
cores the first audio takes about 0.8–0.95 s and transcription 0.5 s.

## On the Core2 (patch 0003)

All of this is off by default upstream. The `core2v11` profile turns it on:

| Option | What it does |
|---|---|
| `MUSE_TTS`, `MUSE_TTS_URL` | Speak replies with the server's `/tts`. If the speaker is muted or the server is down, the reply is shown as text. |
| `MUSE_LOCAL_STT`, `MUSE_STT_URL` | Transcribe on the server and send Muse text. If the server fails, the recording goes up as a voice note as before. |
| `MUSE_SPEECH_TOKEN` | A bearer token for both. Use `https://` URLs with it: certificates are checked against the built-in CA bundle. |
| `MUSE_HANDS_FREE` | Turns end on their own when you stop talking. A tap also starts a turn. |
| `MUSE_FOLLOW_UP_S` | Seconds to keep listening after a reply. The Core2 profile sets **0**, so every turn starts with the wake word. |
| `MUSE_WAKE_WORD` | On-device **"Hey Jarvis"**. |
| `MUSE_VOICE_NOTE_HINT` | Appended to each question: ask for one to three short spoken sentences, without markdown or emoji. |

`muse-gadget/build.sh` writes `TTS_URL`, `STT_URL` and `SPEECH_TOKEN` from
`.env` into the git-ignored build config.

### Wake word

- **The model.** [microWakeWord](https://github.com/kahrendt/microWakeWord)'s
  "Hey Jarvis" v2 model (Apache-2.0, from
  [esphome/micro-wake-word-models](https://github.com/esphome/micro-wake-word-models)),
  run with TensorFlow Lite Micro (`esp-tflite-micro` 1.4.1).
- **Features.** The same features the model was trained on: the TF audio
  microfrontend, vendored in `components/microfrontend` because
  esp-tflite-micro no longer ships it. It produces 40 channels of 30 ms
  windows every 10 ms, configured as in pymicro-features.
- **Cost.** About 6 ms per call, 7–20% of one core. The 18 KB tensor arena is
  in **PSRAM**: the Core2 reallocates its I2S DMA buffers on every mic ↔
  speaker switch, and a 26 KB internal arena starved them.
- **No re-triggers.** The model is streaming and keeps about a second of
  state. That state, and the frontend, are reset at the start of every turn,
  so the wake word you just said can't wake it again.
- **Detection rule.** It wakes when the average score over 5 calls reaches
  247/255. In our tests it scored 247–253.

### When you've stopped talking

The Core2 tracks the room's background level and your voice level:

- **The rule.** A turn ends after **700 ms** below
  `max(floor + 7 dB, voice − 15 dB)`.
- **Transcribing early.** At the first **200 ms** pause, the speech so far is
  already sent to `/stt`. If you say nothing more, the turn's end reuses that
  transcript, so Muse gets your question **about 0.1–0.2 s** after you stop,
  instead of about 0.6 s.
- **Reading the transcript.** If that early transcript ends a sentence and
  not on a word like "and" or "the", the turn can end right away. If it
  doesn't, or it was only the wake word, the Core2 waits up to 1.5 s for you
  to go on.

### Connections

- **One connection per endpoint, for one turn.** The Core2 opens a
  connection each for `/stt` and `/tts` with `GET /health` as soon as a turn
  starts listening. A TLS handshake to a cloud server, about 0.3–1 s on an
  ESP32, then happens while you're still talking. The turn's requests (the
  transcript, then each sentence of the reply) reuse those connections
  through HTTP keep-alive. The server closes idle ones after 120 s.
- **Freed when the turn ends.** Keeping the connections between turns looked
  cheaper, but it froze the avatar:
  - The HTTP client's buffers are 2 KB each, under the SDK's 4 KB
    "always internal" malloc threshold, so they live in internal RAM.
  - The display's SPI transfers need DMA-capable internal RAM.
  - With the connections (and mDNS) kept, idle internal RAM fell from 50 to
    34 KB, and the DMA pool from 29 to 14 KB, with a 7 KB largest block
    during a turn.

  Freeing them at the end of each turn brings idle memory back to boot
  levels (49 KB internal, 29 KB DMA).
- **Stale connections.** If a request fails before any response (the server
  closed the connection), it's retried once on a brand-new client. Reusing
  the old client after a reset hit stale esp-tls state.
- **Faster reconnects.** For `https://` URLs, TLS session tickets let a new
  connection resume the previous session.
- **Voice can't interrupt a reply.** While the Core2 is speaking it doesn't
  listen for the wake word. A tap on the touch strip still interrupts, and a
  cancelled reply closes its connection at once instead of downloading the
  rest of the sentence.

## Measured latency

From the end of the spoken question to the first sound from the Core2, on
the home network. A PC speaker played the prompts and a room mic measured
them (method below).

| | Before | Now |
|---|---|---|
| End of speech detected | 0.7 s of quiet | 0.7 s of quiet |
| Transcript reaches Muse | about 0.6 s later | **0.01–0.2 s later** |
| First sound (the filler) | about 0.7 s after detection | **0.1–0.3 s after detection** |
| **Question end → first sound (room)** | **1.3–1.7 s** | **about 1.0–1.2 s** |

Muse's own reply then takes 1.5–6 s to start arriving. That's the largest
remaining delay, and it's in Muse, not the gadget.

## Testing end to end without a person

We drove the Core2 with a PC speaker:

1. The PC speaker plays Kokoro-synthesized prompts ("Hey Jarvis!", a pause,
   then the question).
2. A USB mic records the room.
3. The Core2's serial log gives its own timings, logged as `timing (ms
   after release)`.

Two rules matter:

- **Wait for the reply to finish** (`muse reply:` in the log) and the room to
  go quiet before the next prompt. Otherwise prompts land in the follow-up
  window and split turns.
- **Open the serial port raw, with echo off** (`stty -F /dev/ttyACM0 raw
  -echo`). With echo on, the Core2's own log comes back to its console,
  which treats letters as bench commands (`d`/`u` press and release the talk
  button, `m` plays a test MP3). The device then drives itself.

## Running the speech server in the cloud

For a Core2 that works without a PC, run the server on a host and use HTTPS:

```sh
docker build -f cloud/Dockerfile -t muse-speech .
docker run -p 8766:8766 -e SPEECH_TOKEN="$(openssl rand -base64 32)" muse-speech
```

- **The image.** It pins the Python packages, checks the Kokoro model files'
  SHA-256, and bakes in Whisper `base.en`, so a cold start downloads nothing.
- **Startup.** It listens on `$PORT` and **refuses to start without
  `SPEECH_TOKEN`**.
- **HTTPS.** Put it behind your host's HTTPS: a platform's managed TLS, or
  a reverse proxy such as Caddy on a VM.
- **The Core2.** Set `TTS_URL` and `STT_URL` to the `https://` URLs and
  `SPEECH_TOKEN` to the same token, then rerun `muse-gadget/build.sh "" flash`.
- **Sizing.** 2 vCPUs and 2 GB of RAM are enough. Prefer an always-on
  instance: a server that has to wake up adds seconds to the first question.
