#!/bin/bash
# bootstrap.sh — entrypoint for schnicklfritz/deepfish
# Pulls model weights from Backblaze B2 if configured, else HuggingFace.
# Designed for a destroy-then-recreate workflow (no QuickPod storage rent).
set -e

WORKSPACE=/workspace
BAKED=/opt/deepfish
mkdir -p "$WORKSPACE"/{references,outputs,scripts,logs,checkpoints}

# =====================================================================
# 1. Privacy env (Dockerfile sets these too; redundant on purpose)
# =====================================================================
export GRADIO_ANALYTICS_ENABLED=False
export HF_HUB_DISABLE_TELEMETRY=1
export HF_HUB_DISABLE_IMPLICIT_TOKEN=1
export TRANSFORMERS_NO_ADVISORY_WARNINGS=1
export DO_NOT_TRACK=1
export DISABLE_TELEMETRY=1

# =====================================================================
# 2. Authenticate B2 if credentials supplied (silent no-op if not)
# =====================================================================
b2_ready=0
if [ -n "$B2_KEY_ID" ] && [ -n "$B2_APP_KEY" ] && [ -n "$B2_BUCKET" ]; then
  if b2 account authorize "$B2_KEY_ID" "$B2_APP_KEY" >/dev/null 2>&1; then
    echo "[bootstrap] B2 authorized; bucket=$B2_BUCKET"
    b2_ready=1
  else
    echo "[bootstrap] WARN: B2 auth failed, falling back to HuggingFace"
  fi
fi

# =====================================================================
# 3. Acquire S2-Pro weights — B2 first, HF fallback, mirror back to B2
# =====================================================================
CKPT_LINK=/app/checkpoints/s2-pro
PERSIST_CKPT=$WORKSPACE/checkpoints/s2-pro

if [ -f "$PERSIST_CKPT/codec.pth" ]; then
  echo "[bootstrap] Weights already on /workspace (persistent volume hit)"
elif [ "$b2_ready" = "1" ] && \
     b2 ls "b2://$B2_BUCKET/deepfish/checkpoints/s2-pro/" 2>/dev/null | grep -q codec.pth; then
  echo "[bootstrap] Pulling weights from B2 (fast path)"
  mkdir -p "$PERSIST_CKPT"
  b2 sync "b2://$B2_BUCKET/deepfish/checkpoints/s2-pro/" "$PERSIST_CKPT/" \
    --noProgress
else
  echo "[bootstrap] Pulling weights from HuggingFace (~15-20GB, slow path)"
  mkdir -p "$PERSIST_CKPT"
  huggingface-cli download fishaudio/s2-pro --local-dir "$PERSIST_CKPT"
  if [ "$b2_ready" = "1" ]; then
    echo "[bootstrap] Mirroring weights to B2 for future pods"
    b2 sync "$PERSIST_CKPT/" "b2://$B2_BUCKET/deepfish/checkpoints/s2-pro/" \
      --noProgress &
    # don't block startup on the upload
  fi
fi
mkdir -p /app/checkpoints
rm -rf "$CKPT_LINK"
ln -s "$PERSIST_CKPT" "$CKPT_LINK"

# =====================================================================
# 4. Optional: pull reference voice from B2 if it's there and not local
# =====================================================================
if [ "$b2_ready" = "1" ] && [ ! -f "$WORKSPACE/references/voice.wav" ]; then
  if b2 ls "b2://$B2_BUCKET/deepfish/references/" 2>/dev/null | grep -q voice.wav; then
    echo "[bootstrap] Pulling reference voice from B2"
    b2 file download "b2://$B2_BUCKET/deepfish/references/voice.wav" \
      "$WORKSPACE/references/voice.wav" --noProgress || true
  fi
fi

# =====================================================================
# 5. Pick chat_app source: dev override on /workspace wins
# =====================================================================
pick() {
  local name=$1
  if [ -f "$WORKSPACE/scripts/$name" ]; then
    echo "$WORKSPACE/scripts/$name"
  else
    echo "$BAKED/$name"
  fi
}
CHAT_APP=$(pick chat_app.py)
echo "[bootstrap] chat_app source: $CHAT_APP"

# =====================================================================
# 6. Config (override via QuickPod env)
# =====================================================================
: "${LLAMA_CKPT:=/app/checkpoints/s2-pro}"
: "${DECODER_CKPT:=/app/checkpoints/s2-pro/codec.pth}"
: "${FS_API_PORT:=8080}"
: "${FS_WEBUI_PORT:=7860}"
: "${CHAT_PORT:=7861}"

# =====================================================================
# 7. Launch Fish API (:8080, background)
# NOTE: verify flag names with `python tools/api_server.py --help` first
# =====================================================================
cd /app
python tools/api_server.py \
  --llama-checkpoint-path "$LLAMA_CKPT" \
  --decoder-checkpoint-path "$DECODER_CKPT" \
  --listen 0.0.0.0:$FS_API_PORT \
  > "$WORKSPACE/logs/api_server.log" 2>&1 &
echo "[bootstrap] Fish API on :$FS_API_PORT (PID $!)"

# =====================================================================
# 8. Launch native Gradio WebUI (:7860, background)
# =====================================================================
python -m tools.webui \
  --llama-checkpoint-path "$LLAMA_CKPT" \
  --decoder-checkpoint-path "$DECODER_CKPT" \
  --listen 0.0.0.0 --port $FS_WEBUI_PORT \
  > "$WORKSPACE/logs/webui.log" 2>&1 &
echo "[bootstrap] Fish WebUI on :$FS_WEBUI_PORT (PID $!)"

# =====================================================================
# 9. Wait for API
# =====================================================================
echo "[bootstrap] Waiting for API (up to 5 min on first cold start)..."
for i in {1..60}; do
  curl -fsS "http://127.0.0.1:$FS_API_PORT/" >/dev/null 2>&1 && \
    { echo "[bootstrap] API up after $((i*5))s"; break; }
  sleep 5
done

# =====================================================================
# 10. Launch chat orchestrator (:7861, foreground)
# Reminder: run `sync.sh push` before destroying the pod to save outputs.
# =====================================================================
exec python "$CHAT_APP"
