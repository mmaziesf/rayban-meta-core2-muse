#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["websockets>=13", "numpy>=1.26", "opencv-python>=4.9", "av>=14"]
# ///
"""Stands in for the iPhone app: sends synthetic frames using the same protocol.

Use it to check the viewer (and anything downstream of it) without the glasses.
"""

import argparse
import fractions
import json
import time

import cv2
import numpy as np
from websockets.sync.client import connect

RESOLUTIONS = {"high": (720, 1280), "medium": (504, 896), "low": (360, 640)}


def frame(i: int, width: int, height: int) -> np.ndarray:
    image = np.zeros((height, width, 3), np.uint8)
    image[:] = (40, 40, 40)
    x = int((i * 7) % width)
    cv2.rectangle(image, (x, height // 3), (x + 80, height // 3 + 80), (0, 160, 255), -1)
    cv2.putText(image, f"fake glasses #{i}", (20, 60), cv2.FONT_HERSHEY_SIMPLEX, 1.0, (255, 255, 255), 2)
    cv2.putText(image, time.strftime("%H:%M:%S"), (20, 110), cv2.FONT_HERSHEY_SIMPLEX, 1.0, (255, 255, 255), 2)
    return image


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", default="ws://127.0.0.1:8765/ingest")
    parser.add_argument("--resolution", choices=RESOLUTIONS, default="medium")
    parser.add_argument("--fps", type=float, default=15)
    parser.add_argument("--quality", type=int, default=60, help="JPEG quality 1-100")
    parser.add_argument("--seconds", type=float, default=0, help="stop after this long (0 = run until Ctrl-C)")
    parser.add_argument("--codec", choices=["jpeg", "hevc"], default="jpeg", help="hevc mimics the app's locked-phone mode")
    args = parser.parse_args()

    width, height = RESOLUTIONS[args.resolution]
    encoder = None
    if args.codec == "hevc":
        import av

        encoder = av.CodecContext.create("libx265", "w")
        encoder.width, encoder.height, encoder.pix_fmt = width, height, "yuv420p"
        encoder.time_base = fractions.Fraction(1, int(args.fps))
        encoder.framerate = int(args.fps)
        # Keyframe every second with parameter sets in front, no B-frames: like the glasses.
        encoder.options = {"x265-params": f"keyint={int(args.fps)}:bframes=0:repeat-headers=1:log-level=error", "tune": "zerolatency"}
    with connect(args.url, max_size=8 * 1024 * 1024) as ws:
        ws.send(json.dumps({"type": "hello", "device": "fake_phone.py", "resolution": args.resolution, "fps": args.fps, "codec": args.codec}))
        ws.send(json.dumps({"type": "log", "message": "fake stream starting"}))
        start = time.monotonic()
        i = 0
        while not args.seconds or time.monotonic() - start < args.seconds:
            if encoder is not None:
                import av

                picture = av.VideoFrame.from_ndarray(frame(i, width, height), format="bgr24").reformat(format="yuv420p")
                picture.pts = i
                for packet in encoder.encode(picture):
                    ws.send(bytes(packet))
            else:
                ok, jpeg = cv2.imencode(".jpg", frame(i, width, height), [cv2.IMWRITE_JPEG_QUALITY, args.quality])
                assert ok
                ws.send(jpeg.tobytes())
            i += 1
            time.sleep(max(0.0, start + i / args.fps - time.monotonic()))
        ws.send(json.dumps({"type": "log", "message": f"fake stream done after {i} frames"}))
    print(f"sent {i} frames")


if __name__ == "__main__":
    main()
