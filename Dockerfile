# syntax=docker/dockerfile:1.7
# schnicklfritz/deepfish — Fish Speech S2-Pro + DeepSeek chat orchestrator
# Strategy: destroy pods aggressively, mirror state to Backblaze B2.
FROM fishaudio/fish-speech:latest

USER root

# Privacy defaults — overridable at runtime
ENV GRADIO_ANALYTICS_ENABLED=False \
    HF_HUB_DISABLE_TELEMETRY=1 \
    HF_HUB_DISABLE_IMPLICIT_TOKEN=1 \
    TRANSFORMERS_NO_ADVISORY_WARNINGS=1 \
    DO_NOT_TRACK=1 \
    DISABLE_TELEMETRY=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

# Runtime deps: openai (DeepSeek), b2 (Backblaze sync), small utilities.
# Single RUN layer.
RUN pip install --no-cache-dir --break-system-packages \
        openai \
        requests \
        soundfile \
        huggingface_hub \
        b2

# Pre-create dirs. Single RUN layer. /workspace gets shadowed by the volume
# mount on QuickPod but this still helps for local `docker run` testing.
RUN mkdir -p \
        /workspace/references \
        /workspace/outputs \
        /workspace/scripts \
        /workspace/logs \
        /workspace/checkpoints \
        /opt/deepfish

# Scripts at /opt/deepfish so /workspace volume mount doesn't shadow them.
# bootstrap.sh prefers /workspace/scripts/* if present (dev override).
COPY bootstrap.sh   /opt/deepfish/bootstrap.sh
COPY sync.sh        /opt/deepfish/sync.sh
COPY chat_app.py    /opt/deepfish/chat_app.py
COPY cli.py         /opt/deepfish/cli.py
RUN chmod +x /opt/deepfish/bootstrap.sh /opt/deepfish/sync.sh

EXPOSE 7860 7861 8080

CMD ["bash", "/opt/deepfish/bootstrap.sh"]

