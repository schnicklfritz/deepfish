#!/bin/bash
# setup.sh — one-shot setup inside a fresh fishaudio/fish-speech:latest QuickPod
# Launch Mode for the pod: SSH Entry (so this script controls startup, not the base entrypoint)
# Usage:
#   curl -sL https://raw.githubusercontent.com/schnicklfritz/deepfish/main/setup.sh | bash
# Idempotent: kills prior service instances and re-runs cleanly.

set -u
WORKSPACE=/workspace
REPO_RAW=https://raw.githubusercontent.com/schnicklfritz/deepfish/main
PY=/app/.venv/bin/python
PIP=/app/.venv/bin/pip

mkdir -p "$WORKSPACE"/{references,outputs,scripts,logs,checkpoints}
LOG="$WORKSPACE/logs/setup.log"
exec > >(tee -a "$LOG") 2>&1
log() { echo "[setup $(date +%T)] $*"; }
log "starting"

# ---------------------------------------------------------------------
# 0. Privacy / telemetry kill
# ---------------------------------------------------------------------
export GRADIO_ANALYTICS_ENABLED=False
export HF_HUB_DISABLE_TELEMETRY=1
export HF_HUB_DISABLE_IMPLICIT_TOKEN=1
export DO_NOT_TRACK=1
export DISABLE_TELEMETRY=1

# ---------------------------------------------------------------------
# 1. Kill any prior service instances so re-runs don't double-launch
# ---------------------------------------------------------------------
pkill -f "tools/run_webui.py"  2>/dev/null || true
pkill -f "tools/api_server.py" 2>/dev/null || true
pkill -f "scripts/chat_app.py" 2>/dev/null || true
sleep 1

# ---------------------------------------------------------------------
# 2. Install our extra pip deps into the base image's venv
# ---------------------------------------------------------------------
log "installing pip deps into /app/.venv"
$PIP install --quiet --no-cache-dir openai requests soundfile b2

# ---------------------------------------------------------------------
# 3. Pull our scripts from GitHub raw (must be pushed to main first)
# ---------------------------------------------------------------------
log "pulling scripts from GitHub raw"
for f in chat_app.py cli.py sync.sh; do
  if curl -fsSL "$REPO_RAW/$f" -o "$WORKSPACE/scripts/$f"; then
    log "  ✓ $f"
  else
    log "  ✗ $f failed — make sure it's pushed to schnicklfritz/deepfish main"
  fi
done
[ -f "$WORKSPACE/scripts/sync.sh" ] && chmod +x "$WORKSPACE/scripts/sync.sh"

# ---------------------------------------------------------------------
# 4. Acquire S2-Pro weights: workspace cache → B2 → HF (slow path)
# ---------------------------------------------------------------------
PERSIST=$WORKSPACE/checkpoints/s2-pro
if [ -f "$PERSIST/codec.pth" ]; then
  log "weights cached at $PERSIST"
elif [ -n "${B2_KEY_ID:-}" ] && [ -n "${B2_APP_KEY:-}" ] && [ -n "${B2_BUCKET:-}" ] && \
     b2 account authorize "$B2_KEY_ID" "$B2_APP_KEY" >/dev/null 2>&1 && \
     b2 ls "b2://$B2_BUCKET/deepfish/checkpoints/s2-pro/" 2>/dev/null | grep -q codec.pth; then
  log "pulling weights from B2"
  mkdir -p "$PERSIST"
  b2 sync "b2://$B2_BUCKET/deepfish/checkpoints/s2-pro/" "$PERSIST/" --noProgress
else
  log "pulling weights from HuggingFace via hf (~15-20GB)"
  mkdir -p "$PERSIST"
  hf download fishaudio/s2-pro --local-dir "$PERSIST"
  if [ -n "${B2_BUCKET:-}" ] && [ -n "${B2_KEY_ID:-}" ] && \
     b2 account authorize "$B2_KEY_ID" "$B2_APP_KEY" >/dev/null 2>&1; then
    log "mirroring weights to B2 in background"
    nohup b2 sync "$PERSIST/" "b2://$B2_BUCKET/deepfish/checkpoints/s2-pro/" \
      --noProgress > "$WORKSPACE/logs/b2_mirror.log" 2>&1 &
  fi
fi

# Symlink so scripts that expect /app/checkpoints/s2-pro find them
mkdir -p /app/checkpoints
rm -rf /app/checkpoints/s2-pro
ln -s "$PERSIST" /app/checkpoints/s2-pro
log "checkpoint linked: /app/checkpoints/s2-pro -> $PERSIST"

# ---------------------------------------------------------------------
# 5. Launch services
# ---------------------------------------------------------------------
LLAMA=/app/checkpoints/s2-pro
DECODER=/app/checkpoints/s2-pro/codec.pth
cd /app

log "starting Gradio webui on :7860 (background, --compile)"
nohup $PY tools/run_webui.py \
  --llama-checkpoint-path "$LLAMA" \
  --decoder-checkpoint-path "$DECODER" \
  --compile \
  > "$WORKSPACE/logs/webui.log" 2>&1 &
log "  webui PID=$!"

log "starting api_server on :8080 (background, --mode tts --compile)"
nohup $PY tools/api_server.py \
  --mode tts \
  --llama-checkpoint-path "$LLAMA" \
  --decoder-checkpoint-path "$DECODER" \
  --listen 0.0.0.0:8080 \
  --compile \
  > "$WORKSPACE/logs/api_server.log" 2>&1 &
log "  api PID=$!"

# ---------------------------------------------------------------------
# 6. Wait for api (first cold start with --compile can take 3-5 min)
# ---------------------------------------------------------------------
log "waiting for api on :8080 (up to 5 min)..."
for i in {1..60}; do
  if curl -fsS http://127.0.0.1:8080/ >/dev/null 2>&1 || \
     curl -fsS http://127.0.0.1:8080/docs >/dev/null 2>&1; then
    log "  api responsive after $((i*5))s"
    break
  fi
  sleep 5
done

# ---------------------------------------------------------------------
# 7. Tell the user what to do next
# ---------------------------------------------------------------------
cat <<EOF

==========================================================
  SETUP DONE
==========================================================

Services running (check logs if anything's wonky):
  webui      → :7860   tail -f /workspace/logs/webui.log
  api (TTS)  → :8080   tail -f /workspace/logs/api_server.log

Browse:
  webui      → http://\$PUBLIC_IPADDR:\$QUICKPOD_PORT_7860
  chat (when running) → http://\$PUBLIC_IPADDR:\$QUICKPOD_PORT_7861

To start the chat app (foreground, in this shell):

  export DEEPSEEK_API_KEY=sk-...
  export REFERENCE_AUDIO=/workspace/references/voice.wav
  export REFERENCE_TEXT="exact transcript of voice.wav"
  $PY /workspace/scripts/chat_app.py

Or one-shot CLI:

  export DEEPSEEK_API_KEY=sk-...
  $PY /workspace/scripts/cli.py "say hello with feeling"

Verify api endpoints before relying on chat_app:
  curl http://127.0.0.1:8080/openapi.json | python3 -m json.tool | head -40

==========================================================
EOF
