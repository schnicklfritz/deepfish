#!/bin/bash
# sync.sh — Backblaze B2 helper for the deepfish workflow.
# Run inside the pod. Required env: B2_KEY_ID, B2_APP_KEY, B2_BUCKET.
#
# Usage:
#   sync.sh pull              # download weights + references from B2
#   sync.sh push-weights      # upload weights to B2 (one-time, after first HF pull)
#   sync.sh push-references   # upload reference voices to B2
#   sync.sh push-outputs      # upload generated wav outputs to B2
#   sync.sh push              # all three pushes
#   sync.sh pre-destroy       # run before destroying a pod: push outputs + refs
set -e

: "${B2_KEY_ID:?B2_KEY_ID not set}"
: "${B2_APP_KEY:?B2_APP_KEY not set}"
: "${B2_BUCKET:?B2_BUCKET not set}"

WORKSPACE=${WORKSPACE:-/workspace}

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
  push)
    $0 push-weights
    $0 push-references
    $0 push-outputs
    ;;
  pre-destroy)
    echo "[sync] pre-destroy: pushing references + outputs (skipping weights — already in B2)"
    $0 push-references
    $0 push-outputs
    echo "[sync] safe to destroy the pod now"
    ;;
  *)
    cat <<EOF
sync.sh — Backblaze B2 helper

Commands:
  pull              Pull weights + references from B2 into /workspace
  push-weights      Push /workspace/checkpoints to B2 (one-time after HF download)
  push-references   Push /workspace/references to B2
  push-outputs      Push /workspace/outputs to B2
  push              All three pushes
  pre-destroy       Push refs + outputs (weights already mirrored)

Env: B2_KEY_ID, B2_APP_KEY, B2_BUCKET
EOF
    ;;
esac
