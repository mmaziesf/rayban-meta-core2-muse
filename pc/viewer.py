#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["websockets>=13", "numpy>=1.26", "opencv-python>=4.9", "openai>=1.60", "faster-whisper>=1.1", "av>=14"]
# ///
"""Shows the glasses camera stream sent by the Glasses Bridge iPhone app.

Protocol, WebSocket at ws://<this-pc>:<port>/ingest:
  text    {"type": "hello", "device": ..., "resolution": ..., "fps": ...} once,
          then {"type": "log", "message": ...} for app log lines
  binary  one JPEG per message, or one HEVC access unit in Annex B form
          (the app's "keep streaming when locked" mode; keyframes carry VPS/SPS/PPS)

The M5Stack Core2 connects to ws://<this-pc>:<port>/core2 and pulls frames
(see core2-firmware/src/main.cpp for that side of the protocol).

GET http://<this-pc>:<port>/snapshot.jpg returns the latest frame (640 px on
the long side) for the Muse gadget's glasses.capture command, or 503 when the
glasses have not streamed for 5 seconds.

Keys in the window: q quits, s saves a snapshot.
"""

import argparse
import json
import queue
import socket
import threading
import time
from pathlib import Path

import cv2
import numpy as np
from http import HTTPStatus

from websockets.datastructures import Headers
from websockets.exceptions import ConnectionClosed
from websockets.http11 import Response
from websockets.sync.server import ServerConnection, serve

from agent import Agent, MealLog, Transcriber, shrink

# The Core2's WebSocket library drops messages over 15 KB.
CORE2_MAX_JPEG = 14 * 1024


class LatestFrame:
    """Most recent JPEG plus per-second stats, shared between the socket and UI threads."""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._jpeg: bytes | None = None
        self._seq = 0
        self._count = 0
        self._bytes = 0
        self._window_start = time.monotonic()
        self.fps = 0.0
        self.kbps = 0.0
        self.updated_at = 0.0  # time.monotonic() of the last frame

    def put(self, jpeg: bytes) -> None:
        with self._lock:
            if self._count == 0 and time.monotonic() - self._window_start > 2.0:
                # First frame after an idle gap: start measuring from now, not from the gap.
                self._window_start = time.monotonic()
            self._jpeg = jpeg
            self.updated_at = time.monotonic()
            self._seq += 1
            self._count += 1
            self._bytes += len(jpeg)
            elapsed = time.monotonic() - self._window_start
            if elapsed >= 1.0:
                self.fps = self._count / elapsed
                self.kbps = self._bytes / 1024 / elapsed
                self._count = 0
                self._bytes = 0
                self._window_start = time.monotonic()

    def get(self) -> tuple[int, bytes | None]:
        with self._lock:
            return self._seq, self._jpeg


class HevcDecoder:
    """Decodes the app's HEVC stream; each WebSocket message is one complete frame."""

    def __init__(self) -> None:
        import av

        self._av = av
        self._codec = av.CodecContext.create("hevc", "r")
        self.errors = 0

    def decode(self, access_unit: bytes) -> list[np.ndarray]:
        try:
            frames = self._codec.decode(self._av.Packet(access_unit))
        except self._av.error.FFmpegError:
            self.errors += 1  # e.g. P-frames before the first keyframe
            return []
        return [frame.to_ndarray(format="bgr24") for frame in frames]


def is_annex_b(message: bytes) -> bool:
    return message.startswith(b"\x00\x00\x00\x01") or message.startswith(b"\x00\x00\x01")


def local_addresses() -> list[str]:
    addresses = set()
    try:
        # No packet is sent; this only asks the kernel which interface routes outward.
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.connect(("192.0.2.1", 9))
            addresses.add(s.getsockname()[0])
    except OSError:
        pass
    try:
        for info in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
            addresses.add(info[4][0])
    except OSError:
        pass
    return sorted(a for a in addresses if not a.startswith("127."))


class Core2Hub:
    """Messages (status lines, answers) queued for every connected Core2."""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._queues: list[list[dict]] = []
        self.last_status = "Waiting for phone"

    def attach(self) -> list[dict]:
        queue = [{"type": "status", "text": self.last_status}]
        with self._lock:
            self._queues.append(queue)
        return queue

    def detach(self, queue: list[dict]) -> None:
        with self._lock:
            self._queues.remove(queue)

    def send(self, message: dict) -> None:
        with self._lock:
            if message.get("type") == "status":
                self.last_status = message["text"]
            for queue in self._queues:
                queue.append(message)

    def status(self, text: str) -> None:
        self.send({"type": "status", "text": text})

    def answer(self, text: str) -> None:
        self.send({"type": "answer", "text": text})

    def take(self, queue: list[dict]) -> list[dict]:
        with self._lock:
            items = queue[:]
            queue.clear()
            return items


class Assistant:
    """Runs questions and meal logging one at a time on a worker thread."""

    def __init__(self, latest: LatestFrame, hub: Core2Hub, meal_watch_seconds: float) -> None:
        self.latest = latest
        self.hub = hub
        self.agent = Agent()
        self.transcriber = Transcriber()
        self.meals = MealLog()
        self._jobs: "queue.Queue[tuple]" = queue.Queue()
        threading.Thread(target=self._work, daemon=True).start()
        if meal_watch_seconds > 0:
            threading.Thread(target=self._watch_meals, args=(meal_watch_seconds,), daemon=True).start()
        where = f"{self.agent.model} at {self.agent.base_url}" if self.agent.configured else "NOT configured"
        print(f"[agent] {where}; meal log in {self.meals.directory}", flush=True)

    def submit(self, kind: str, *args) -> None:
        self._jobs.put((kind, args))

    def _frames(self) -> list[bytes]:
        _, jpeg = self.latest.get()
        return [jpeg] if jpeg else []

    def _work(self) -> None:
        while True:
            kind, args = self._jobs.get()
            try:
                if kind == "voice":
                    pcm, rate = args
                    self.hub.status("Transcribing...")
                    question = self.transcriber.transcribe(pcm, rate)
                    print(f"[agent] heard: {question!r}", flush=True)
                    if not question:
                        self.hub.status("Didn't catch that")
                        continue
                    self._ask(question)
                elif kind == "ask":
                    self._ask(*args)
                elif kind == "meal":
                    self._log_meal(source="button")
                elif kind == "undo_meal":
                    removed = self.meals.remove_last()
                    self.hub.status(f"Removed: {removed}" if removed else "Nothing to undo")
            except Exception as error:  # keep the worker alive; show the failure on the Core2
                print(f"[agent] {kind} failed: {error!r}", flush=True)
                self.hub.answer(f"Error: {error}")

    def _ask(self, question: str) -> None:
        frames = self._frames()
        self.hub.status(f"Q: {question}")
        print(f"[agent] asking: {question!r} with {len(frames)} frame(s)", flush=True)
        answer = self.agent.ask(question, frames)
        print(f"[agent] answer: {answer!r}", flush=True)
        self.hub.answer(answer)

    def _log_meal(self, source: str, analysis: dict | None = None, frame: bytes | None = None) -> None:
        frame = frame or (self._frames() or [None])[0]
        if frame is None:
            self.hub.answer("No glasses frame to log yet.")
            return
        if analysis is None:
            if not self.agent.configured:
                self.meals.add(frame, {"is_meal": True, "summary": "photo only (agent not configured)"}, source)
                self.hub.answer("Meal photo saved. Add MODEL_API_KEY to get food and calorie estimates.")
                return
            self.hub.status("Analyzing meal...")
            analysis = self.agent.analyze_meal(frame)
        if not analysis.get("is_meal"):
            self.hub.answer(f"No meal found: {analysis.get('summary', '')}")
            return
        self.meals.add(frame, analysis, source)
        kcal = analysis.get("total_kcal")
        print(f"[meal] logged ({source}): {analysis}", flush=True)
        self.hub.answer(f"Logged: {analysis.get('summary', 'meal')}" + (f" (~{kcal} kcal)" if kcal else "") + "\nHold C to undo.")

    def _watch_meals(self, interval: float) -> None:
        """Passive logging: a cheap yes/no food check every interval, a full analysis on yes."""
        while True:
            time.sleep(interval)
            if not self.agent.configured or time.time() - self.meals.last_logged < 20 * 60:
                continue
            frame = (self._frames() or [None])[0]
            if frame is None or time.monotonic() - self.latest.updated_at > 5:
                continue  # glasses not streaming right now
            try:
                if self.agent.is_food(frame):
                    analysis = self.agent.analyze_meal(frame)
                    if analysis.get("is_meal"):
                        self._log_meal(source="passive", analysis=analysis, frame=frame)
            except Exception as error:
                print(f"[meal] watch check failed: {error!r}", flush=True)


def fit_for_core2(jpeg: bytes, width: int, height: int) -> bytes | None:
    """Center-crops to the Core2's aspect ratio, resizes, and re-encodes under CORE2_MAX_JPEG."""
    image = cv2.imdecode(np.frombuffer(jpeg, np.uint8), cv2.IMREAD_COLOR)
    if image is None:
        return None
    h, w = image.shape[:2]
    target = width / height
    if w / h > target:
        crop = int(h * target)
        image = image[:, (w - crop) // 2 : (w - crop) // 2 + crop]
    else:
        crop = int(w / target)
        image = image[(h - crop) // 2 : (h - crop) // 2 + crop, :]
    image = cv2.resize(image, (width, height), interpolation=cv2.INTER_AREA)
    for quality in (75, 65, 55, 45, 35, 25):
        ok, out = cv2.imencode(".jpg", image, [cv2.IMWRITE_JPEG_QUALITY, quality])
        if ok and len(out) <= CORE2_MAX_JPEG:
            return out.tobytes()
    return None


def serve_core2(ws: ServerConnection, latest: LatestFrame, hub: Core2Hub, assistant: Assistant) -> None:
    peer = ws.remote_address[0]
    print(f"[core2] connected from {peer}", flush=True)
    width, height = 240, 280
    wants_frame = False
    sent_seq = -1
    sent = 0
    audio: bytearray | None = None
    audio_rate = 16000
    outbox = hub.attach()
    try:
        while True:
            for message in hub.take(outbox):
                ws.send(json.dumps(message))
            try:
                message = ws.recv(timeout=0.02)
            except TimeoutError:
                message = None
            if isinstance(message, bytes):
                if audio is not None:
                    audio.extend(message)
            elif isinstance(message, str):
                data = json.loads(message)
                kind = data.get("type")
                if kind == "hello":
                    width, height = int(data["width"]), int(data["height"])
                    print(f"[core2] screen area {width}x{height}", flush=True)
                elif kind == "next":
                    wants_frame = True
                elif kind == "audio_start":
                    audio = bytearray()
                    audio_rate = int(data.get("rate", 16000))
                elif kind == "audio_end" and audio is not None:
                    seconds = len(audio) / 2 / audio_rate
                    print(f"[core2] voice question: {seconds:.1f} s of audio", flush=True)
                    assistant.submit("voice", bytes(audio), audio_rate)
                    audio = None
                elif kind == "button":
                    button = data.get("id")
                    print(f"[core2] button {button}", flush=True)
                    if button == "A":
                        assistant.submit("ask", "What am I looking at? Describe it briefly.")
                    elif button == "C":
                        assistant.submit("meal")
                    elif button == "C_HOLD":
                        assistant.submit("undo_meal")
            if wants_frame:
                seq, jpeg = latest.get()
                if jpeg is not None and seq != sent_seq:
                    sent_seq = seq
                    small = fit_for_core2(jpeg, width, height)
                    if small is not None:
                        ws.send(small)
                        wants_frame = False
                        sent += 1
    except ConnectionClosed:
        pass
    finally:
        hub.detach(outbox)
        print(f"[core2] {peer} disconnected after {sent} frames", flush=True)


def make_snapshot_responder(latest: LatestFrame):
    """Serves plain HTTP GET /snapshot.jpg before the WebSocket handshake."""

    def process_request(connection: ServerConnection, request) -> Response | None:
        if request.path.split("?", 1)[0] != "/snapshot.jpg":
            return None
        _, jpeg = latest.get()
        if jpeg is None or time.monotonic() - latest.updated_at > 5:
            return connection.respond(HTTPStatus.SERVICE_UNAVAILABLE, "glasses are not streaming\n")
        body = shrink(jpeg, max_side=640, quality=80)
        print(f"[snapshot] served {len(body)} bytes to {connection.remote_address[0]}", flush=True)
        headers = Headers(
            [("Content-Type", "image/jpeg"), ("Content-Length", str(len(body))), ("Cache-Control", "no-store")]
        )
        return Response(HTTPStatus.OK, "OK", headers, body)

    return process_request


def make_handler(latest: LatestFrame, record_dir: Path | None, hub: Core2Hub, assistant: Assistant):
    def handler(ws: ServerConnection) -> None:
        path = ws.request.path if ws.request is not None else None
        if path == "/core2":
            serve_core2(ws, latest, hub, assistant)
            return
        if path != "/ingest":
            ws.close(1008, "unknown path")
            return
        peer = ws.remote_address[0]
        print(f"[viewer] phone connected from {peer}", flush=True)
        frames = 0
        hevc: HevcDecoder | None = None
        recording = None
        try:
            for message in ws:
                if isinstance(message, bytes) and is_annex_b(message):
                    if hevc is None:
                        hevc = HevcDecoder()
                        print("[viewer] receiving HEVC (works with the phone locked)", flush=True)
                        if record_dir is not None:
                            recording = (record_dir / time.strftime("glasses-%Y%m%d-%H%M%S.h265")).open("ab")
                    if recording is not None:
                        recording.write(message)
                    for image in hevc.decode(message):
                        ok, jpeg = cv2.imencode(".jpg", image, [cv2.IMWRITE_JPEG_QUALITY, 85])
                        if ok:
                            latest.put(jpeg.tobytes())
                            frames += 1
                    continue
                if isinstance(message, bytes):
                    latest.put(message)
                    frames += 1
                    if record_dir is not None:
                        (record_dir / f"{time.time_ns()}.jpg").write_bytes(message)
                    continue
                try:
                    data = json.loads(message)
                except json.JSONDecodeError:
                    print(f"[phone] {message}", flush=True)
                    continue
                if data.get("type") == "hello":
                    hub.status("Glasses streaming")
                    print(
                        f"[viewer] hello from {data.get('device')}: "
                        f"{data.get('resolution')} @ {data.get('fps')} fps, {data.get('codec', 'jpeg')}",
                        flush=True,
                    )
                elif data.get("type") == "log":
                    print(f"[phone] {data.get('message')}", flush=True)
                else:
                    print(f"[phone] {data}", flush=True)
        finally:
            if recording is not None:
                recording.close()
            if hevc is not None and hevc.errors:
                print(f"[viewer] {hevc.errors} HEVC packets could not be decoded", flush=True)
            hub.status("Phone disconnected")
            print(f"[viewer] phone {peer} disconnected after {frames} frames", flush=True)

    return handler


def placeholder(port: int) -> np.ndarray:
    image = np.zeros((480, 640, 3), np.uint8)
    lines = ["Waiting for the iPhone app...", "", "Enter one of these in the app:"]
    lines += [f"  {address}:{port}" for address in local_addresses()] or ["  (no network address found)"]
    for i, text in enumerate(lines):
        cv2.putText(image, text, (24, 60 + i * 36), cv2.FONT_HERSHEY_SIMPLEX, 0.8, (230, 230, 230), 2)
    return image


def window_open(title: str) -> bool:
    # OpenCV 5's Qt backend raises instead of returning 0 once the window is closed.
    try:
        return cv2.getWindowProperty(title, cv2.WND_PROP_VISIBLE) >= 1
    except cv2.error:
        return False


def run_window(latest: LatestFrame, port: int, snapshot_dir: Path) -> None:
    title = "Glasses Bridge"
    cv2.namedWindow(title, cv2.WINDOW_NORMAL)
    shown_seq = -1
    image = placeholder(port)
    last_frame_at = 0.0
    while True:
        seq, jpeg = latest.get()
        if jpeg is not None and seq != shown_seq:
            shown_seq = seq
            decoded = cv2.imdecode(np.frombuffer(jpeg, np.uint8), cv2.IMREAD_COLOR)
            if decoded is not None:
                image = decoded
                last_frame_at = time.monotonic()
                h, w = image.shape[:2]
                label = f"{w}x{h}  {latest.fps:.1f} fps  {latest.kbps:.0f} KB/s"
                cv2.putText(image, label, (10, 28), cv2.FONT_HERSHEY_SIMPLEX, 0.7, (0, 0, 0), 4)
                cv2.putText(image, label, (10, 28), cv2.FONT_HERSHEY_SIMPLEX, 0.7, (0, 255, 0), 2)
        elif last_frame_at and time.monotonic() - last_frame_at > 3:
            image = placeholder(port)
            last_frame_at = 0.0
        cv2.imshow(title, image)
        key = cv2.waitKey(10) & 0xFF
        if key == ord("q") or not window_open(title):
            break
        if key == ord("s") and jpeg is not None:
            snapshot_dir.mkdir(parents=True, exist_ok=True)
            path = snapshot_dir / time.strftime("snapshot-%Y%m%d-%H%M%S.jpg")
            path.write_bytes(jpeg)
            print(f"[viewer] saved {path}", flush=True)
    cv2.destroyAllWindows()


def run_headless(latest: LatestFrame) -> None:
    """Prints stats instead of opening a window (for SSH or testing)."""
    last_seq = 0
    while True:
        time.sleep(1)
        seq, jpeg = latest.get()
        if seq != last_seq and jpeg is not None:
            decoded = cv2.imdecode(np.frombuffer(jpeg, np.uint8), cv2.IMREAD_COLOR)
            shape = "undecodable" if decoded is None else f"{decoded.shape[1]}x{decoded.shape[0]}"
            print(f"[viewer] {shape}  {latest.fps:.1f} fps  {latest.kbps:.0f} KB/s  total {seq}", flush=True)
            last_seq = seq


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--record", type=Path, help="save every received JPEG into this directory")
    parser.add_argument("--snapshots", type=Path, default=Path("snapshots"), help="where 's' saves frames")
    parser.add_argument("--headless", action="store_true", help="print stats instead of opening a window")
    parser.add_argument(
        "--meal-watch",
        type=float,
        default=0,
        metavar="SECONDS",
        help="passive meal logging: check a frame for food every SECONDS (0 = off; needs the agent)",
    )
    args = parser.parse_args()

    if args.record:
        args.record.mkdir(parents=True, exist_ok=True)

    latest = LatestFrame()
    hub = Core2Hub()
    assistant = Assistant(latest, hub, args.meal_watch)
    server = serve(
        make_handler(latest, args.record, hub, assistant),
        "0.0.0.0",
        args.port,
        max_size=8 * 1024 * 1024,
        process_request=make_snapshot_responder(latest),
    )
    threading.Thread(target=server.serve_forever, daemon=True).start()
    print(f"[viewer] listening on ws://0.0.0.0:{args.port}/ingest", flush=True)
    for address in local_addresses():
        print(f"[viewer] enter in the app: {address}:{args.port}", flush=True)

    try:
        if args.headless:
            run_headless(latest)
        else:
            run_window(latest, args.port, args.snapshots)
    except KeyboardInterrupt:
        pass
    finally:
        server.shutdown()


if __name__ == "__main__":
    main()
