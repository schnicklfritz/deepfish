#!/bin/bash
# setup.sh — fail-loud setup inside a fresh fishaudio/fish-speech:latest QuickPod
# Launch Mode: SSH Entry
# Usage:
#   curl -sL https://raw.githubusercontent.com/schnicklfritz/deepfish/main/setup.sh | bash
# Idempotent. Safe to re-run.

set -euo pipefail        # FAIL LOUD on any error, undefined var, or pipe failure
trap 'echo "[setup] ERROR on line $LINENO: command exited with $?"' ERR

WORKSPACE=${WORKSPACE:-/workspace}
REPO_RAW=https://raw.githubusercontent.com/schnicklfritz/deepfish/main
VENV=/app/.venv

# ---------------------------------------------------------------------
# 0. Sanity checks — fail fast if image isn't what we expect
# ---------------------------------------------------------------------
[ -d "$VENV" ]              || { echo "[setup] FATAL: $VENV missing"; exit 1; }
[ -x "$VENV/bin/python" ]   || { echo "[setup] FATAL: $VENV/bin/python missing"; exit 1; }
[ -x "/usr/bin/uv" ]        || { echo "[setup] FATAL: uv missing from /usr/bin"; exit 1; }
[ -f "/app/tools/api_server.py" ] || { echo "[setup] FATAL: api_server.py missing"; exit 1; }

# Put venv first on PATH so b2, hf, python all resolve to the right ones
export PATH="$VENV/bin:$PATH"

mkdir -p "$WORKSPACE"/{references,outputs,scripts,logs,checkpoints,torch_cache}
LOG="$WORKSPACE/logs/setup.log"
exec > >(tee -a "$LOG") 2>&1
log() { echo "[setup $(date +%T)] $*"; }
log "==========================================="
log "deepfish setup starting (fail-loud mode)"
log "==========================================="

# ---------------------------------------------------------------------
# 1. Privacy / telemetry kill
# ---------------------------------------------------------------------
export GRADIO_ANALYTICS_ENABLED=False
export HF_HUB_DISABLE_TELEMETRY=1
export HF_HUB_DISABLE_IMPLICIT_TOKEN=1
export DO_NOT_TRACK=1
export DISABLE_TELEMETRY=1
export HF_HUB_ENABLE_HF_TRANSFER=1   # fast HF download (no resume; whole files at once)

# ---------------------------------------------------------------------
# 2. torch.compile cache (GPU-arch-segregated)
# ---------------------------------------------------------------------
GPU_ARCH=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null \
            | head -1 | tr -d '. ')
[ -z "$GPU_ARCH" ] && GPU_ARCH="unknown"
export TORCHINDUCTOR_CACHE_DIR="$WORKSPACE/torch_cache/sm_$GPU_ARCH"
export TORCHINDUCTOR_FX_GRAPH_CACHE=1
export TORCHINDUCTOR_AUTOGRAD_CACHE=1
mkdir -p "$TORCHINDUCTOR_CACHE_DIR"
log "GPU arch: sm_$GPU_ARCH"
log "torch.compile cache: $TORCHINDUCTOR_CACHE_DIR"

# ---------------------------------------------------------------------
# 3. Kill any prior service instances (idempotent re-runs)
# ---------------------------------------------------------------------
pkill -f "tools/run_webui.py"  2>/dev/null || true
pkill -f "tools/api_server.py" 2>/dev/null || true
pkill -f "scripts/chat_app.py" 2>/dev/null || true
sleep 1

# ---------------------------------------------------------------------
# 4. Install pip extras using uv (this venv has no pip binary)
# ---------------------------------------------------------------------
log "installing extras into $VENV via uv"
uv pip install --quiet --python "$VENV/bin/python" \
    openai requests soundfile b2 hf_transfer huggingface_hub

# Verify the install actually took
"$VENV/bin/python" -c "import openai, requests, soundfile, b2sdk, hf_transfer, huggingface_hub" \
  || { log "FATAL: pip extras failed to import"; exit 1; }
log "  ✓ extras importable"

# ---------------------------------------------------------------------
# 5. Pull our scripts from GitHub raw
# ---------------------------------------------------------------------
log "pulling scripts from GitHub raw"
for f in chat_app.py cli.py sync.sh; do
  if ! curl -fsSL "$REPO_RAW/$f" -o "$WORKSPACE/scripts/$f"; then
    log "FATAL: failed to fetch $f from $REPO_RAW"
    exit 1
  fi
  log "  ✓ $f"
done
chmod +x "$WORKSPACE/scripts/sync.sh"

# ---------------------------------------------------------------------
# 6. B2 auth (optional; setup continues without B2)
# ---------------------------------------------------------------------
B2_OK=0
if [ -n "${B2_KEY_ID:-}" ] && [ -n "${B2_APP_KEY:-}" ] && [ -n "${B2_BUCKET:-}" ]; then
  if b2 account authorize "$B2_KEY_ID" "$B2_APP_KEY" >/dev/null 2>&1; then
    log "B2 authorized; bucket=$B2_BUCKET"
    B2_OK=1
  else
    log "WARN: B2 auth failed — continuing without B2"
  fi
else
  log "B2 env vars not set — skipping B2 (will HF download fresh)"
fi

# ---------------------------------------------------------------------
# 7. Weights: workspace → B2 → HF
# ---------------------------------------------------------------------
PERSIST=$WORKSPACE/checkpoints/s2-pro

if [ -f "$PERSIST/codec.pth" ] && [ -f "$PERSIST/config.json" ]; then
  log "weights cached at $PERSIST"
elif [ "$B2_OK" = "1" ] && \
     b2 ls "b2://$B2_BUCKET/deepfish/checkpoints/s2-pro/" 2>/dev/null | grep -q codec.pth; then
  log "pulling weights from B2"
  mkdir -p "$PERSIST"
  b2 sync "b2://$B2_BUCKET/deepfish/checkpoints/s2-pro/" "$PERSIST/" --no-progress
else
  log "pulling weights from HF (~15-20GB)"
  mkdir -p "$PERSIST"
  hf download fishaudio/s2-pro --local-dir "$PERSIST"
  if [ "$B2_OK" = "1" ]; then
    log "mirroring weights to B2 in background"
    nohup b2 sync "$PERSIST/" "b2://$B2_BUCKET/deepfish/checkpoints/s2-pro/" \
      --no-progress > "$WORKSPACE/logs/b2_mirror.log" 2>&1 &
  fi
fi

# Verify weights are actually usable before proceeding
[ -f "$PERSIST/codec.pth" ]   || { log "FATAL: codec.pth missing"; exit 1; }
[ -f "$PERSIST/config.json" ] || { log "FATAL: config.json missing"; exit 1; }
log "  ✓ codec.pth + config.json present"

# ---------------------------------------------------------------------
# 8. Pull torch cache + references from B2 if available
# ---------------------------------------------------------------------
if [ "$B2_OK" = "1" ] && [ "$GPU_ARCH" != "unknown" ]; then
  if b2 ls "b2://$B2_BUCKET/deepfish/torch_cache/sm_$GPU_ARCH/" 2>/dev/null | grep -q .; then
    if [ -z "$(ls -A "$TORCHINDUCTOR_CACHE_DIR" 2>/dev/null)" ]; then
      log "pulling torch.compile cache (sm_$GPU_ARCH) from B2"
      b2 sync "b2://$B2_BUCKET/deepfish/torch_cache/sm_$GPU_ARCH/" \
              "$TORCHINDUCTOR_CACHE_DIR/" --no-progress || true
    fi
  fi

  log "pulling references from B2"
  b2 sync "b2://$B2_BUCKET/deepfish/references/" \
          "$WORKSPACE/references/" --no-progress 2>/dev/null || true
fi

# Symlink so scripts that look at /app/checkpoints/s2-pro find them
mkdir -p /app/checkpoints
rm -rf /app/checkpoints/s2-pro
ln -s "$PERSIST" /app/checkpoints/s2-pro

# ---------------------------------------------------------------------
# 9. Launch api_server (foreground compile, then background serving)
# ---------------------------------------------------------------------
LLAMA=/app/checkpoints/s2-pro
DECODER=/app/checkpoints/s2-pro/codec.pth
cd /app

log "starting api_server on :8080 (--mode tts --compile)"
nohup python tools/api_server.py \
  --mode tts \
  --llama-checkpoint-path "$LLAMA" \
  --decoder-checkpoint-path "$DECODER" \
  --listen 0.0.0.0:8080 \
  --compile > "$WORKSPACE/logs/api_server.log" 2>&1 &
API_PID=$!
log "  api PID=$API_PID"

# ---------------------------------------------------------------------
# 10. Wait for api to actually respond (NOT lie about it)
# ---------------------------------------------------------------------
log "waiting for api on :8080 (cold-cache first run: 5-10 min)..."
api_ready=0
for i in {1..180}; do
  if ! kill -0 $API_PID 2>/dev/null; then
    log "FATAL: api_server died — see /workspace/logs/api_server.log"
    tail -30 "$WORKSPACE/logs/api_server.log"
    exit 1
  fi
  if curl -fsS http://127.0.0.1:8080/ >/dev/null 2>&1; then
    api_ready=1
    log "  ✓ api responsive after $((i*5))s"
    break
  fi
  sleep 5
done
[ "$api_ready" = "1" ] || { log "FATAL: api didn't respond in 15 min"; exit 1; }

# ---------------------------------------------------------------------
# 11. Auto-register references from $WORKSPACE/references/
# Looks for any *.wav with a matching *.txt transcript.
# ---------------------------------------------------------------------
log "auto-registering references"
shopt -s nullglob
registered=0
for audio in "$WORKSPACE/references/"*.wav; do
  id=$(basename "$audio" .wav)
  txt="$WORKSPACE/references/$id.txt"
  if [ -f "$txt" ]; then
    text=$(cat "$txt")
    if curl -fsS -X POST http://127.0.0.1:8080/v1/references/add \
        -F "id=$id" \
        -F "audio=@$audio" \
        -F "text=$text" >/dev/null 2>&1; then
      log "  ✓ registered: $id"
      registered=$((registered+1))
    else
      log "  ✗ failed: $id"
    fi
  else
    log "  - skipping $id (no $id.txt transcript)"
  fi
done
log "registered $registered voice(s)"

# ---------------------------------------------------------------------
# 12. Final summary
# ---------------------------------------------------------------------
cat <<EOF

==========================================================
  SETUP DONE (verified)
==========================================================

api running, $registered voice(s) registered, weights+cache hot.

  api log:  tail -f /workspace/logs/api_server.log
  setup log: /workspace/logs/setup.log

To chat (browser, voice dropdown for all registered voices):
  export DEEPSEEK_API_KEY=\$DEEPSEEK_API_KEY    # from pod env
  python /workspace/scripts/chat_app.py
  # then open http://\$PUBLIC_IPADDR:\$QUICKPOD_PORT_7861

To one-shot (CLI):
  python /workspace/scripts/cli.py --voice morrison "your prompt"

Before destroying pod (saves cache + new refs + outputs to B2):
  bash /workspace/scripts/sync.sh pre-destroy

==========================================================
EOF
