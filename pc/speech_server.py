#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10,<3.14"
# dependencies = ["kokoro-onnx>=0.4", "lameenc>=1.7", "numpy>=1.26", "scipy>=1.11", "faster-whisper>=1.1"]
# ///
"""Speech for the Muse gadget: speech-to-text and text-to-speech on the PC.

  POST /stt  raw 16-bit mono PCM (?rate=16000) -> the transcript, text/plain
  POST /tts  text/plain -> streamed MP3

Transcribing on the PC (Whisper, warm) and sending Muse text is faster than
sending a voice note for Muse to transcribe.

  pc/speech_server.py [--port 8766] [--voice af_bella] [--pitch 4] [--tempo 1.05] [--loudness -9] [--flat]
  GET  /health -> "ok" (for a cloud host's health check; no token needed)

With --token (or SPEECH_TOKEN in the environment), /stt and /tts answer only
requests carrying "Authorization: Bearer <token>": required once the server
is reachable from the internet (see cloud/README.md), optional on a LAN.

--pitch raises the voice by semitones for a bright, toy-like character (Kokoro
speaks slower, then a single resample raises pitch and formants together);
--tempo sets the final speaking speed.

POST /tts with a text/plain body (the Muse reply). The reply is cleaned up
for speech (markdown, emoji and links dropped), split into sentences, and
each sentence is synthesised with Kokoro and streamed as soon as it's ready
(chunked MP3, one continuous encoder, so there are no gaps or clicks). The
first audio is ready a few hundred ms after the request.

Small speakers (the Core2's) can't reproduce Kokoro's low end, which holds
about half its energy, and its output averages about -23 dBFS. So unless
--flat, the speech is high-passed at 180 Hz, given a gentle +2 dB presence
lift at 2.5 kHz, and levelled to --loudness dBFS RMS under a soft limiter.

The MP3 is 16 kHz (--rate): the Core2 plays at 16 kHz and its own resampler
is linear with no anti-aliasing, which made 24 kHz speech sound metallic.
Resampling here (polyphase, low-passed) lets it pass the audio through.

Model files: kokoro-v1.0.onnx and voices-v1.0.bin from
https://github.com/thewh1teagle/kokoro-onnx/releases (model-files-v1.0), in
~/.local/share/kokoro or --models DIR. Voices: af_heart (warm, default),
af_bella, bf_emma, am_michael, and the rest of Kokoro's list.
"""

import argparse
import hmac
import os
import re
from fractions import Fraction
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import lameenc
import numpy as np
from kokoro_onnx import Kokoro
from faster_whisper import WhisperModel
from scipy import signal

RATE = 24000          # Kokoro's output
OUT_RATE = 16000      # what the MP3 carries (the Core2's playback rate)
MAX_TEXT = 8192       # bytes of reply text per /tts request
MAX_PCM = 60 * 48000 * 2   # a minute of audio per /stt request


def peaking(f0: float, gain_db: float, q: float):
    """RBJ peaking-EQ biquad."""
    a = 10 ** (gain_db / 40)
    w = 2 * np.pi * f0 / RATE
    alpha = np.sin(w) / (2 * q)
    b = np.array([1 + alpha * a, -2 * np.cos(w), 1 - alpha * a])
    den = np.array([1 + alpha / a, -2 * np.cos(w), 1 - alpha / a])
    return b / den[0], den / den[0]


HIGHPASS = signal.butter(2, 180, "highpass", fs=RATE, output="sos")
PRESENCE = signal.tf2sos(*peaking(2500, 2.0, 0.8))
VOICING = np.vstack([HIGHPASS, PRESENCE])


class Shaper:
    """Speaker EQ and levelling with filter state kept across sentences."""

    def __init__(self, loudness_db: float, flat: bool) -> None:
        self.target = loudness_db
        self.flat = flat
        self.zi = signal.sosfilt_zi(VOICING) * 0.0

    def __call__(self, x: np.ndarray) -> np.ndarray:
        if self.flat:
            return np.clip(x, -1, 1)
        y, self.zi = signal.sosfilt(VOICING, x, zi=self.zi)
        # Bring the sentence to -20 dBFS, then a smooth 4:1 compressor (5 ms
        # envelope) evens out syllables without the distortion of clipping,
        # then make up to the target level. A gentle soft limiter catches the rest.
        rms = np.sqrt(np.mean(y**2)) + 1e-9
        y = y * min(10 ** ((-20.0 - 20 * np.log10(rms)) / 20), 10.0)
        a = 1.0 - np.exp(-1.0 / (0.005 * RATE))
        env = signal.lfilter([a], [1.0, a - 1.0], np.abs(y)) + 1e-9
        threshold, ratio = 10 ** (-26 / 20), 4.0
        gain = np.where(env > threshold, (env / threshold) ** (1.0 / ratio - 1.0), 1.0)
        y = y * gain
        rms = np.sqrt(np.mean(y**2)) + 1e-9
        y = y * 10 ** ((self.target - 20 * np.log10(rms)) / 20)
        return np.tanh(1.1 * y) / np.tanh(1.1)


SENTENCE_END = re.compile(r"(?<=[.!?…])\s+|\n+")
MARKDOWN = re.compile(r"[*_`#>|~]+")
LINK = re.compile(r"https?://\S+|\[([^\]]*)\]\([^)]*\)")
EMOJI = re.compile("[\U0001F000-\U0001FAFF\U00002600-\U000027BF\U0000FE0F\U0000200D]")


def speakable(text: str) -> list[str]:
    """Plain sentences to speak, short ones merged so the voice flows."""
    text = LINK.sub(lambda m: m.group(1) or "", text)
    text = EMOJI.sub("", MARKDOWN.sub("", text))
    text = re.sub(r"^\s*[-•\d]+[.)]?\s+", "", text, flags=re.M)   # list markers
    text = text.replace("—", ", ").replace("–", ", ")
    text = re.sub(r"[ \t]+", " ", text)
    text = re.sub(r" +([,.!?;:])", r"\1", text)
    text = re.sub(r",\s*,", ",", text)
    parts = [p.strip() for p in SENTENCE_END.split(text) if p and p.strip()]
    merged: list[str] = []
    for p in parts:
        if merged and len(merged[-1]) < 24:
            merged[-1] += " " + p
        else:
            merged.append(p)
    return merged


class Speaker:
    def __init__(self, models: Path, voice: str, speed: float, loudness: float = -9.0, flat: bool = False,
                 pitch: float = 0.0) -> None:
        self.pitch = pitch
        self.loudness = loudness
        self.flat = flat
        self.kokoro = Kokoro(str(models / "kokoro-v1.0.onnx"), str(models / "voices-v1.0.bin"))
        self.voice = voice
        self.speed = speed
        self.lock = threading.Lock()   # one synthesis at a time keeps latency predictable
        self.cache: dict[str, bytes] = {}   # short phrases (the gadget's acknowledgements), served instantly
        self.kokoro.create("Ready.", voice=voice, speed=speed, lang="en-us")   # warm up

    def stream(self, text: str):
        if len(text) <= 48 and text in self.cache:
            yield self.cache[text]
            return
        chunks = []
        for chunk in self._synthesize(text):
            chunks.append(chunk)
            yield chunk
        if len(text) <= 48:
            self.cache[text] = b"".join(chunks)

    def warm(self, phrases: list[str]) -> None:
        for p in phrases:
            for _ in self.stream(p):
                pass

    def _synthesize(self, text: str):
        encoder = lameenc.Encoder()
        encoder.set_bit_rate(56)
        encoder.set_in_sample_rate(OUT_RATE)
        shape = Shaper(self.loudness, self.flat)
        encoder.set_channels(1)
        encoder.set_quality(2)
        for sentence in speakable(text):
            ratio = 2 ** (self.pitch / 12)   # >1 raises the pitch
            with self.lock:
                samples, rate = self.kokoro.create(sentence, voice=self.voice, speed=self.speed / ratio, lang="en-us")
            assert rate == RATE
            shaped = shape(samples.astype(np.float64))
            # 24 kHz -> 16 kHz (low-passed), played `ratio` faster: pitch up, tempo restored.
            step = Fraction(OUT_RATE / (RATE * ratio)).limit_denominator(240)
            shaped = signal.resample_poly(shaped, step.numerator, step.denominator)
            peak = np.abs(shaped).max() if len(shaped) else 0.0
            if peak > 0.82:   # MP3 overshoot measured at up to ~1.6 dB on breathy onsets
                shaped *= 0.82 / peak
            pcm = (np.clip(shaped, -1, 1) * 32767).astype(np.int16)
            pause = np.zeros(int(0.12 * OUT_RATE), np.int16)   # a breath between sentences
            chunk = encoder.encode(np.concatenate([pcm, pause]).tobytes())
            if chunk:
                yield bytes(chunk)
        tail = encoder.flush()
        if tail:
            yield bytes(tail)


# The Core2's wake word lands at the start of the recording; Muse only needs the question.
WAKE_PREFIX = re.compile(r"^\W*(?:(?:hey|hi|okay|ok)[\s,]+)?jarvis\b[\s,.!?]*", re.IGNORECASE)


# What Whisper says about noise or silence: never a real question to the gadget.
PHANTOMS = {"you", "thank you", "thanks", "thank you very much", "thanks for watching",
            "thank you for watching", "bye", "okay", "oh", "uh", "um", "hmm", "so"}


class Listener:
    """Warm Whisper for short push-to-talk clips."""

    def __init__(self, model: str) -> None:
        self.model = WhisperModel(model, device="cpu", compute_type="int8")
        self.lock = threading.Lock()
        self.transcribe(np.zeros(16000, np.float32))   # warm up

    def transcribe(self, audio: np.ndarray) -> str:
        # Far-field speech arrives at -35..-45 dBFS: bring it to about -20 dBFS
        # (at most +20 dB) so the VAD doesn't drop it and Whisper hears it clearly.
        rms = float(np.sqrt(np.mean(audio**2))) + 1e-9
        audio = np.clip(audio * min(10 ** ((-20 - 20 * np.log10(rms)) / 20), 10.0), -1, 1).astype(np.float32)
        with self.lock:
            segments, _ = self.model.transcribe(audio, language="en", beam_size=1, vad_filter=True,
                                                vad_parameters={"threshold": 0.3},
                                                condition_on_previous_text=False)
            # Segments Whisper itself rates as probably not speech are dropped.
            text = " ".join(s.text.strip() for s in segments if s.no_speech_prob < 0.6).strip()
            if re.sub(r"[^a-z ]", "", text.lower()).strip() in PHANTOMS or not re.search(r"[A-Za-z]", text):
                text = ""
            stripped = WAKE_PREFIX.sub("", text, count=1)
            return stripped[:1].upper() + stripped[1:] if stripped else stripped


def make_handler(speaker: Speaker, listener: Listener, token: str):
    expected = f"Bearer {token}".encode()

    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"   # connections stay open: the gadget reuses them (TLS is costly on it)
        timeout = 120                   # ...until idle this long

        def do_GET(self):
            if self.path.partition("?")[0] != "/health":
                self.send_error(404)
                return
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", "2")
            self.end_headers()
            self.wfile.write(b"ok")

        def authorized(self) -> bool:
            if not token or hmac.compare_digest(self.headers.get("Authorization", "").encode(), expected):
                return True
            print(f"[speech] {self.client_address[0]}: refused, no valid token", flush=True)
            self.send_error(401)
            return False

        def do_POST(self):
            path, _, query = self.path.partition("?")
            if not self.authorized():
                return
            if path == "/stt":
                self.stt(query)
                return
            if path != "/tts":
                self.send_error(404)
                return
            length = int(self.headers.get("Content-Length") or 0)
            if length > MAX_TEXT:
                self.send_error(413)
                return
            text = self.rfile.read(length).decode("utf-8", "replace") if length else ""
            if not text.strip():
                self.send_error(400, "empty text")
                return
            started = time.monotonic()
            self.send_response(200)
            self.send_header("Content-Type", "audio/mpeg")
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            sent, first = 0, None
            try:
                for chunk in speaker.stream(text):
                    if first is None:
                        first = time.monotonic() - started
                    self.wfile.write(f"{len(chunk):x}\r\n".encode() + chunk + b"\r\n")
                    self.wfile.flush()
                    sent += len(chunk)
                self.wfile.write(b"0\r\n\r\n")
            except (BrokenPipeError, ConnectionResetError):
                print(f"[tts] {self.client_address[0]} hung up", flush=True)
                return
            print(f"[tts] {self.client_address[0]}: {len(text)} chars -> {sent // 1024} KB, "
                  f"first audio {first or 0:.2f}s, total {time.monotonic() - started:.2f}s", flush=True)

        def stt(self, query: str):
            started = time.monotonic()
            rate = 16000
            for part in query.split("&"):
                if part.startswith("rate="):
                    rate = int(part[5:]) if part[5:].isdigit() else 0
            length = int(self.headers.get("Content-Length") or 0)
            if length > MAX_PCM or not 8000 <= rate <= 48000:
                self.send_error(413 if length > MAX_PCM else 400)
                return
            pcm = self.rfile.read(length) if length else b""
            uploaded = time.monotonic() - started
            audio = np.frombuffer(pcm[: len(pcm) // 2 * 2], np.int16).astype(np.float32) / 32768.0
            if rate != 16000 and len(audio):
                audio = signal.resample_poly(audio, 16000, rate).astype(np.float32)
            text = listener.transcribe(audio) if len(audio) > 1600 else ""
            body = text.encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            print(f"[stt] {self.client_address[0]}: {len(audio) / 16000:.1f}s -> {text!r} "
                  f"in {time.monotonic() - started:.2f}s (upload {uploaded:.2f}s)", flush=True)

        def log_message(self, *args):
            pass

    return Handler


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--port", type=int, default=8766)
    ap.add_argument("--voice", default="af_bella")
    ap.add_argument("--pitch", type=float, default=4.0, help="semitones up (toy/cartoon character)")
    ap.add_argument("--tempo", "--speed", dest="speed", type=float, default=1.05, help="final speaking speed")
    ap.add_argument("--models", type=Path, default=Path.home() / ".local/share/kokoro")
    ap.add_argument("--loudness", type=float, default=-9.0,
                    help="target speech level, dBFS RMS (-9: loudest that stays clear on the Core2)")
    ap.add_argument("--flat", action="store_true", help="no speaker EQ or levelling")
    ap.add_argument("--whisper", default="base.en", help="faster-whisper model for /stt")
    ap.add_argument("--token", default=os.environ.get("SPEECH_TOKEN", ""),
                    help="require 'Authorization: Bearer TOKEN' (default: $SPEECH_TOKEN)")
    args = ap.parse_args()
    speaker = Speaker(args.models, args.voice, args.speed, args.loudness, args.flat, args.pitch)
    # The Core2's acknowledgements (muse_chat_session.cpp queue_filler), ready before they're asked for.
    speaker.warm(["Mm, let me see.", "Okay, one moment.", "Hmm, let me think.",
                  "Sure, just a sec.", "Alright, let me check.", "Ooh, good one. One sec."])
    listener = Listener(args.whisper)
    server = ThreadingHTTPServer(("0.0.0.0", args.port), make_handler(speaker, listener, args.token))
    print(f"[speech] {args.voice} {args.pitch:+g} st at tempo {args.speed}, {'flat' if args.flat else f'{args.loudness:g} dBFS, speaker EQ'}, whisper {args.whisper}; listening on http://0.0.0.0:{args.port} (/stt, /tts, /health), {'token required' if args.token else 'no token'}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
