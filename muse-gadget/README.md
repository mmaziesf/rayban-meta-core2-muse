# Muse Gadget SDK patches

Patches for [facebookincubator/muse-gadget-sdk](https://github.com/facebookincubator/muse-gadget-sdk)
at commit `812c46f` (2026-10-09):

1. `0001`: M5Stack Core2 **v1.1** (AXP2101 PMU) support, as a new `core2v11` build profile.
2. `0002`: the `glasses.capture` command, so Muse can see the latest Ray-Ban Meta frame.
3. `0003`: voice: on-device "Hey Jarvis" wake word, spoken replies and transcription on your
   speech server, hands-free turns that end when you stop talking, connections opened at the wake word.
4. `0004`: glasses frames straight from the iPhone app (mDNS), fetched as each turn starts.

```sh
./setup.sh [DIR]          # clone upstream into DIR (default ../../muse-gadget-sdk) and apply
./build.sh [DIR] [flash]  # build with GADGET_SDK_TOKEN, TTS_URL, STT_URL, SPEECH_TOKEN, GLASSES_RELAY_URL from ../.env
```

Details in [docs/core2-muse-gadget.md](../docs/core2-muse-gadget.md) and [docs/voice.md](../docs/voice.md).
