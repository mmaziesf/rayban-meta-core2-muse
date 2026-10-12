"""Speech-to-text, the vision agent, and the meal log used by viewer.py.

The agent talks to any OpenAI-compatible chat API. By default that is Meta's
Model API (Muse Spark); set these in the environment or in a .env file at the
repository root (falling back to ~/Documents/core2_projects/.env):

  MODEL_API_KEY    Meta Model API key (https://dev.meta.ai → API keys)
  AGENT_BASE_URL   default https://api.meta.ai/v1
  AGENT_MODEL      default muse-spark-1.3
  AGENT_API_KEY    overrides MODEL_API_KEY, e.g. for another provider
  MEAL_LOG_DIR     where meal photos and meals.jsonl go (default <repo>/meal-log)
"""

import base64
import json
import os
import re
import threading
import time
from pathlib import Path

import cv2
import numpy as np

REPO_ROOT = Path(__file__).resolve().parents[1]
ENV_FILES = (REPO_ROOT / ".env", Path.home() / "Documents" / "core2_projects" / ".env")

SYSTEM_PROMPT = (
    "You are a personal assistant that sees through the user's Ray-Ban Meta glasses. "
    "The images are the most recent frames from the glasses camera, newest last. "
    "Answer in at most 60 words of plain text with no markdown: the answer is shown "
    "on a small 240x280 screen. If the images do not show what is needed, say so briefly."
)

MEAL_PROMPT = (
    "Look at this photo from the user's glasses. If it shows food the user is eating or "
    "about to eat, estimate what it is. Reply with only a JSON object: "
    '{"is_meal": true|false, "items": [{"name": str, "portion": str, "kcal": int}], '
    '"total_kcal": int, "protein_g": int, "carbs_g": int, "fat_g": int, '
    '"summary": "<= 12 words"}. Use is_meal false and empty items if there is no food.'
)

FOOD_CHECK_PROMPT = (
    "Is the person wearing these glasses currently eating, or looking at a plate or "
    "serving of food they are about to eat? Answer with exactly one word: yes or no."
)


def load_env() -> None:
    """Fills os.environ from the first .env file found, without overriding real env vars."""
    env_file = next((f for f in ENV_FILES if f.exists()), None)
    if env_file is None:
        return
    for line in env_file.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        os.environ.setdefault(key.strip(), value.strip().strip('"').strip("'"))


def shrink(jpeg: bytes, max_side: int = 768, quality: int = 80) -> bytes:
    """Downscales a frame before sending it to the model (fewer image tokens, faster)."""
    image = cv2.imdecode(np.frombuffer(jpeg, np.uint8), cv2.IMREAD_COLOR)
    if image is None:
        return jpeg
    h, w = image.shape[:2]
    scale = max_side / max(h, w)
    if scale < 1:
        image = cv2.resize(image, (int(w * scale), int(h * scale)), interpolation=cv2.INTER_AREA)
    ok, out = cv2.imencode(".jpg", image, [cv2.IMWRITE_JPEG_QUALITY, quality])
    return out.tobytes() if ok else jpeg


class Transcriber:
    """Local Whisper (faster-whisper) speech-to-text; the model loads on first use."""

    def __init__(self, model: str = "small.en") -> None:
        self._model_name = model
        self._model = None
        self._lock = threading.Lock()

    def transcribe(self, pcm16: bytes, sample_rate: int) -> str:
        from faster_whisper import WhisperModel

        with self._lock:
            if self._model is None:
                self._model = WhisperModel(self._model_name, device="cpu", compute_type="int8")
            audio = np.frombuffer(pcm16, np.int16).astype(np.float32) / 32768.0
            if sample_rate != 16000:
                audio = cv2.resize(audio.reshape(1, -1), (int(len(audio) * 16000 / sample_rate), 1)).ravel()
            segments, _ = self._model.transcribe(audio, language="en", beam_size=1, vad_filter=True)
            return " ".join(s.text.strip() for s in segments).strip()


class Agent:
    def __init__(self) -> None:
        load_env()
        self.base_url = os.environ.get("AGENT_BASE_URL", "https://api.meta.ai/v1")
        self.model = os.environ.get("AGENT_MODEL", "muse-spark-1.3")
        self._key = os.environ.get("AGENT_API_KEY") or os.environ.get("MODEL_API_KEY")
        self._client = None

    @property
    def configured(self) -> bool:
        return bool(self._key)

    def _chat(
        self,
        prompt: str,
        images: list[bytes],
        system: str | None = SYSTEM_PROMPT,
        reasoning_effort: str | None = None,
    ) -> str:
        if self._client is None:
            from openai import OpenAI

            self._client = OpenAI(base_url=self.base_url, api_key=self._key, timeout=60)
        content: list[dict] = [{"type": "text", "text": prompt}]
        for jpeg in images:
            data = base64.b64encode(jpeg).decode()
            content.append({"type": "image_url", "image_url": {"url": f"data:image/jpeg;base64,{data}"}})
        messages = [{"role": "user", "content": content}]
        if system:
            messages.insert(0, {"role": "system", "content": system})
        extra = {"reasoning_effort": reasoning_effort} if reasoning_effort else {}
        response = self._client.chat.completions.create(model=self.model, messages=messages, **extra)
        return (response.choices[0].message.content or "").strip()

    def ask(self, question: str, frames: list[bytes]) -> str:
        if not self.configured:
            return f'Agent not configured (no MODEL_API_KEY). You asked: "{question}"'
        return self._chat(question, [shrink(f) for f in frames])

    def is_food(self, frame: bytes) -> bool:
        # Muse Spark always reasons ("none" is rejected); "minimal" cut this yes/no
        # check from ~536 to ~181 output tokens (~$0.0025 -> ~$0.001) in testing.
        answer = self._chat(
            FOOD_CHECK_PROMPT, [shrink(frame, max_side=384, quality=70)], system=None, reasoning_effort="minimal"
        )
        return answer.strip().lower().startswith("yes")

    def analyze_meal(self, frame: bytes) -> dict:
        text = self._chat(MEAL_PROMPT, [shrink(frame, max_side=1024)], system=None)
        match = re.search(r"\{.*\}", text, re.S)
        if not match:
            return {"is_meal": False, "summary": "could not read the model's answer", "raw": text}
        try:
            return json.loads(match.group(0))
        except json.JSONDecodeError:
            return {"is_meal": False, "summary": "could not read the model's answer", "raw": text}


class MealLog:
    """Photos plus one JSON line per meal in MEAL_LOG_DIR (default <repo>/meal-log)."""

    def __init__(self, directory: Path | None = None) -> None:
        load_env()
        self.directory = directory or Path(os.environ.get("MEAL_LOG_DIR") or REPO_ROOT / "meal-log").expanduser()
        self.last_logged = 0.0

    def add(self, frame: bytes, analysis: dict, source: str) -> Path:
        self.directory.mkdir(parents=True, exist_ok=True)
        stamp = time.strftime("%Y%m%d-%H%M%S")
        photo = self.directory / f"meal-{stamp}.jpg"
        photo.write_bytes(frame)
        entry = {"time": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "source": source, "photo": photo.name, **analysis}
        with (self.directory / "meals.jsonl").open("a") as f:
            f.write(json.dumps(entry) + "\n")
        self.last_logged = time.time()
        return photo

    def remove_last(self) -> str | None:
        """Undo for the most recent entry; returns its summary."""
        log = self.directory / "meals.jsonl"
        if not log.exists():
            return None
        lines = log.read_text().splitlines()
        if not lines:
            return None
        entry = json.loads(lines[-1])
        log.write_text("".join(line + "\n" for line in lines[:-1]))
        (self.directory / entry["photo"]).unlink(missing_ok=True)
        return entry.get("summary", "meal")
