#!/bin/bash
# sync.sh — Backblaze B2 helper for the deepfish workflow.
# Run inside the pod. Required env: B2_KEY_ID, B2_APP_KEY, B2_BUCKET.
set -e

: "${B2_KEY_ID:?B2_KEY_ID not set}"
: "${B2_APP_KEY:?B2_APP_KEY not set}"
: "${B2_BUCKET:?B2_BUCKET not set}"

WORKSPACE=${WORKSPACE:-/workspace}

# Detect GPU arch for cache path
GPU_ARCH=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null | head -1 | tr -d '. ' || echo "unknown")
[ -z "$GPU_ARCH" ] && GPU_ARCH="unknown"
CACHE_DIR="$WORKSPACE/torch_cache/sm_$GPU_ARCH"

b2 account authorize "$B2_KEY_ID" "$B2_APP_KEY" >/dev/null

cmd=${1:-help}
case "$cmd" in
  pull)
    echo "[sync] pulling weights..."
    mkdir -p "$WORKSPACE/checkpoints/s2-pro"
    b2 sync "b2://$B2_BUCKET/deepfish/checkpoints/s2-pro/" \
            "$WORKSPACE/checkpoints/s2-pro/" --noProgress
    echo "[sync] pulling references..."
    mkdir -p "$WORKSPACE/references"
    b2 sync "b2://$B2_BUCKET/deepfish/references/" \
            "$WORKSPACE/references/" --noProgress || true
    echo "[sync] pulling torch.compile cache (sm_$GPU_ARCH)..."
    mkdir -p "$CACHE_DIR"
    b2 sync "b2://$B2_BUCKET/deepfish/torch_cache/sm_$GPU_ARCH/" \
            "$CACHE_DIR/" --noProgress || true
    ;;
  push-weights)
    echo "[sync] pushing weights..."
    b2 sync "$WORKSPACE/checkpoints/s2-pro/" \
            "b2://$B2_BUCKET/deepfish/checkpoints/s2-pro/" --noProgress
    ;;
  push-references)
    echo "[sync] pushing references..."
    b2 sync "$WORKSPACE/references/" \
            "b2://$B2_BUCKET/deepfish/references/" --noProgress
    ;;
  push-outputs)
    echo "[sync] pushing outputs..."
    b2 sync "$WORKSPACE/outputs/" \
            "b2://$B2_BUCKET/deepfish/outputs/" --noProgress
    ;;
  push-cache)
    echo "[sync] pushing torch.compile cache (sm_$GPU_ARCH)..."
    if [ -d "$CACHE_DIR" ] && [ -n "$(ls -A $CACHE_DIR 2>/dev/null)" ]; then
      b2 sync "$CACHE_DIR/" \
              "b2://$B2_BUCKET/deepfish/torch_cache/sm_$GPU_ARCH/" --noProgress
    else
      echo "[sync] cache dir empty or missing, skipping"
    fi
    ;;
  push)
    $0 push-weights
    $0 push-references
    $0 push-outputs
    $0 push-cache
    ;;
  pre-destroy)
    echo "[sync] pre-destroy: pushing references + outputs + cache (weights already in B2)"
    $0 push-references
    $0 push-outputs
    $0 push-cache
    echo "[sync] safe to destroy the pod now"
    ;;
  *)
    cat <<EOF
sync.sh — Backblaze B2 helper

Commands:
  pull              Pull weights + refs + torch cache from B2 into /workspace
  push-weights      Push /workspace/checkpoints to B2
  push-references   Push /workspace/references to B2
  push-outputs      Push /workspace/outputs to B2
  push-cache        Push torch.compile cache for this GPU arch to B2
  push              All four pushes
  pre-destroy       Push refs + outputs + cache (skips weights — already mirrored)

Env: B2_KEY_ID, B2_APP_KEY, B2_BUCKET
GPU arch detected: sm_$GPU_ARCH
Cache dir: $CACHE_DIR
EOF
    ;;
esac
