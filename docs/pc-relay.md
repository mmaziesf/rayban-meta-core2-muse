# PC relay and agent

The relay is optional now: the Core2 can get glasses frames straight from the
iPhone app. Use it to watch or record the stream, for the vision agent and
for meal logging. The Core2's voice comes from a different script,
`pc/speech_server.py` (port 8766), described in [voice.md](voice.md).

`pc/viewer.py` is a single [uv](https://docs.astral.sh/uv/) script. Its
dependencies are declared inline, so this is all you need:

```sh
pc/viewer.py                 # window with the live stream (q quits, s saves a snapshot)
pc/viewer.py --headless      # print stats instead (SSH, servers)
pc/viewer.py --record DIR    # also save the stream (.h265 for HEVC, .jpg per frame for JPEG)
pc/viewer.py --meal-watch 20 # passive meal logging, see meal-logging.md
pc/viewer.py --port 8765     # default port
```

On start it prints the address to enter in the app. Open TCP **8765** if a
firewall is on (`sudo ufw allow 8765/tcp`).

## Endpoints (all on port 8765)

| Path | Who uses it | What |
|---|---|---|
| `ws /ingest` | iPhone app | frames in (HEVC or JPEG), plus hello and log messages |
| `GET /snapshot.jpg` | Muse gadget (`glasses.capture`), anything else | latest frame, 640 px; `503` when no frame has arrived in the last 5 s |
| `ws /core2` | standalone Core2 firmware | pulled 240×280 frames; push-to-talk audio; answers |

Quick checks:
```sh
curl -o snap.jpg -w "%{http_code}\n" http://localhost:8765/snapshot.jpg
pc/fake_phone.py --codec hevc --seconds 10   # synthetic stream, no glasses needed
```

## Agent (`pc/agent.py`)

The agent is only used by the standalone Core2 firmware and the meal log;
the Muse gadget talks to Muse directly. It needs `MODEL_API_KEY` in `.env`.

- **Model:** `muse-spark-1.3` through Meta's OpenAI-compatible Model API
  (`https://api.meta.ai/v1`). To use another provider, set `AGENT_BASE_URL`,
  `AGENT_MODEL` and `AGENT_API_KEY`.
- **Speech-to-text:** local [faster-whisper](https://github.com/SYSTRAN/faster-whisper)
  (`small.en`, int8, CPU), with voice-activity filtering so silence isn't
  transcribed.
- **Speed:** Muse Spark always reasons, so a vision answer took about 10–14 s
  in our tests.
- **Meal log:** saved to `MEAL_LOG_DIR` (default `./meal-log`) as photos
  plus `meals.jsonl`.
