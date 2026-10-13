# syntax=docker/dockerfile:1.7
# The gadget's speech server (pc/speech_server.py) as a container for a cloud
# host, so the Core2 needs no PC. Build from the repository root:
#
#   docker build -f cloud/Dockerfile -t muse-speech .
#   docker run -p 8766:8766 -e SPEECH_TOKEN=... muse-speech
#
# The host must terminate HTTPS in front of it (see cloud/README.md).
FROM python:3.13-slim

RUN pip install --no-cache-dir \
        kokoro-onnx==0.6.1 lameenc==1.8.4 numpy==2.5.4 scipy==1.18.1 faster-whisper==1.2.1

# Kokoro v1.0 model files, checked against the ones the server was tuned with.
ADD --checksum=sha256:7d5df8ecf7d4b1878015a32686053fd0eebe2bc377234608764cc0ef3636a6c5 \
    https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/kokoro-v1.0.onnx /models/
ADD --checksum=sha256:bca610b8308e8d99f32e6fe4197e7ec01679264efed0cac9140fe9c29f1fbf7d \
    https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/voices-v1.0.bin /models/

# Whisper base.en in the image, so a cold start doesn't download it.
ENV HF_HOME=/models/hf
RUN python -c "from faster_whisper import WhisperModel; WhisperModel('base.en', device='cpu', compute_type='int8')"

RUN useradd --system --home /app speech && chmod -R a+rX /models
COPY pc/speech_server.py /app/speech_server.py
USER speech
WORKDIR /app

# Most hosts pass the port to listen on in $PORT; SPEECH_TOKEN comes from the
# host's secret store, never the image.
ENV PORT=8766 PYTHONUNBUFFERED=1
EXPOSE 8766
CMD ["sh", "-c", "[ -n \"$SPEECH_TOKEN\" ] || { echo 'SPEECH_TOKEN is not set: refusing to serve speech to the whole internet' >&2; exit 1; }; exec python speech_server.py --models /models --port \"$PORT\""]
