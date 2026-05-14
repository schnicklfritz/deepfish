# schnicklfritz/deepfish

Fish Speech S2-Pro voice cloning + DeepSeek V4-Flash chat, packaged for QuickPod.

```
chat prompt → DeepSeek V4-Flash (free-form S2-Pro tags) → Fish S2-Pro TTS → wav
```

All inference local. All audio stays on the pod. Backblaze B2 mirrors weights + refs + outputs so you can destroy pods between sessions instead of paying QuickPod storage rent.

---

## The cost strategy

QuickPod now charges meaningful rent on stopped-pod storage. So the workflow is:

```
create pod → pull from B2 → use → push outputs to B2 → destroy pod
```

| Where | Holds | Cost |
|---|---|---|
| **DockerHub** (`schnicklfritz/deepfish:latest`) | Image (~10 GB) | Free (public) |
| **HuggingFace** (`fishaudio/s2-pro`) | Model weights (~15-20 GB) | Free |
| **Backblaze B2** (your bucket) | Weights mirror + references + outputs | ~$6/TB/month |
| **QuickPod** (running pod) | Active compute + ephemeral working set | hourly compute rate |
| **QuickPod** (stopped pod) | nothing — we destroy instead | $0 |

First-ever pod: bootstrap pulls weights from HuggingFace (~5-10 min) and mirrors them to B2 in the background. Every subsequent fresh pod: pull from B2 (faster + under your control).

---

## QuickPod template fields

### Required

| Field | Value |
|---|---|
| **Template Name** | `deepfish` |
| **Docker Image Path** | `schnicklfritz/deepfish:latest` |
| **Disk Space** | **60 GB** — destroy-then-recreate means we don't need huge headroom; locked at creation |
| **Description** | Fish S2-Pro voice clone + DeepSeek chat with free-form emotive tags. B2-backed state. |

### Docker Options (minimal known-good)

```
--gpus all
--runtime=nvidia
-p 22:22
-p 7860:7860
-p 7861:7861
-p 8080:8080
-v /workspace:/workspace
--env NVIDIA_VISIBLE_DEVICES=all
--shm-size=8gb
```

If the pod hangs in "creating" with no error, strip to:
```
--gpus all
-p 22:22
-p 7861:7861
-v /workspace:/workspace
```
…and add the rest back one line at a time.

### Launch Mode

**Docker Entrypoint** with run options:
```
bash /opt/deepfish/bootstrap.sh
```

### On Start Scripts

Leave blank.

### Environment Variables (per-pod, not in the template)

| Key | Required | Notes |
|---|---|---|
| `DEEPSEEK_API_KEY` | ✅ | Your DeepSeek API key |
| `B2_KEY_ID` | optional* | Backblaze app-key ID |
| `B2_APP_KEY` | optional* | Backblaze app key |
| `B2_BUCKET` | optional* | e.g. `deepfish-mirror` |
| `DEEPSEEK_MODEL` | optional | Defaults to `deepseek-v4-flash` |
| `REFERENCE_AUDIO` | optional | Defaults to `/workspace/references/voice.wav` |
| `REFERENCE_TEXT` | optional | Transcript of the reference clip — biggest fidelity multiplier |

*If B2 vars are unset, bootstrap silently falls back to HF for every pod. The economics get worse but the system still works.

---

## One-time Backblaze setup

```bash
# On your laptop, once:
# 1. Create a B2 bucket "deepfish-mirror" (or whatever name you like).
#    Region: wherever's geographically close to the QuickPod hosts you usually
#    rent from. Default Encryption: turn this ON (SSE-B2, B2-managed keys).
#
# 2. Create an application key SCOPED TO THAT BUCKET ONLY:
#    Capabilities: listFiles, readFiles, writeFiles, deleteFiles
#    Save the keyID and applicationKey strings.
#
# 3. (Optional) Bootstrap the bucket with the weights from your own machine,
#    so the very first pod doesn't pay HF download time:
pip install b2
b2 account authorize <keyID> <appKey>
huggingface-cli download fishaudio/s2-pro --local-dir ./s2-pro
b2 sync ./s2-pro b2://deepfish-mirror/deepfish/checkpoints/s2-pro/
```

After this, every pod boot pulls from B2 (~5-15 minutes depending on region, vs ~5-10 min from HF) and the slow HF path is only a fallback.

---

## Per-session lifecycle

```bash
# 1) Create pod with the template above + your env vars in the QuickPod UI.
#    Watch the console — bootstrap logs B2 auth, weight pull, server startup.

# 2) On first pod ever, after weights download from HF, bootstrap mirrors them
#    to B2 in the background. Future pods skip that.

# 3) scp your reference clip if it's not already in B2:
scp -P $QUICKPOD_PORT_22 voice.wav root@$PUBLIC_IPADDR:/workspace/references/voice.wav

# 4) Browse to http://$PUBLIC_IPADDR:$QUICKPOD_PORT_7861 — chat away.

# 5) BEFORE DESTROYING THE POD — push anything new to B2:
ssh root@$PUBLIC_IPADDR "bash /opt/deepfish/sync.sh pre-destroy"

# 6) Destroy the pod in the QuickPod console. No more storage charges.
```

---

## sync.sh reference

Inside the pod:

| Command | What it does |
|---|---|
| `sync.sh pull` | Download weights + references from B2 into `/workspace/` |
| `sync.sh push-weights` | Upload `/workspace/checkpoints` to B2 (one-time after first HF pull, auto-done by bootstrap) |
| `sync.sh push-references` | Upload `/workspace/references` to B2 |
| `sync.sh push-outputs` | Upload `/workspace/outputs` to B2 |
| `sync.sh push` | All three pushes |
| `sync.sh pre-destroy` | Push refs + outputs (weights already mirrored), then it's safe to destroy |

---

## Privacy threat surface (updated)

| Who could see what | Mitigation |
|---|---|
| **Fish Audio** | Nothing — open-source code, weights from HF, no telemetry. Verify with the tcpdump recipe below. |
| **HuggingFace** | Knows you downloaded `fishaudio/s2-pro` (model is public). Once mirrored to B2, future pods skip HF entirely. |
| **DeepSeek** | Sees chat **text only**. Not the audio. |
| **Backblaze** | Sees your weights (public anyway), references, outputs — as encrypted blobs if SSE-B2 enabled. Cannot read them, only store them. |
| **QuickPod** | Hosts the running pod. Their ToS governs. Accept this or use a different provider. |

### Verify nothing leaks to fish.audio

```bash
apt-get update && apt-get install -y tcpdump
tcpdump -i any -n 'not src net 127.0.0.0/8 and not dst net 127.0.0.0/8' \
  | grep -Ei 'fish\.audio|fishaudio\.com'
# send a chat in another window. should print NOTHING.
```

---

## Reference audio prep

| Property | Target |
|---|---|
| Duration | 10–30 s |
| Format | mono .wav, 16/24-bit, 44.1 kHz |
| Content | Single speaker, no music, no reverb |
| Source pick | Interviews >> song acapellas. Acapella reverb gets baked into the clone. |
| Transcript | Set `REFERENCE_TEXT` to the exact clip words. Biggest fidelity multiplier. |

---

## Build & deploy

```
laptop → git push → GitHub Actions builds → DockerHub schnicklfritz/deepfish:latest
                                          ↓
                                  QuickPod pulls on pod creation
```

### CI

- Push to `main` → builds and pushes `:latest` + `:sha-<short>`
- Push a `v1.2.3` tag → also pushes `:1.2.3` + `:1.2`
- ~5-10 min uncached, ~30-60 s cached
- Secrets needed in the GitHub repo: `DOCKERHUB_USERNAME`, `DOCKERHUB_TOKEN` (Read+Write)

### Live edit without rebuilding

bootstrap.sh prefers `/workspace/scripts/chat_app.py` over the baked-in `/opt/deepfish/chat_app.py`:

```bash
scp -P $QUICKPOD_PORT_22 chat_app.py root@$PUBLIC_IPADDR:/workspace/scripts/chat_app.py
ssh root@$PUBLIC_IPADDR "pkill -f chat_app; cd /workspace/scripts && nohup python chat_app.py &"
```

Once happy, commit; next image push bakes it in.

---

## Verify api_server flags on first boot

```bash
ssh root@$PUBLIC_IPADDR "cd /app && python tools/api_server.py --help | head -30"
```

If `--llama-checkpoint-path` / `--decoder-checkpoint-path` aren't the actual flags, edit `bootstrap.sh`, commit, push, rebuild. 2-line patch.

---

## Cost back-of-napkin

| Item | Rate | Per session (2 hr) |
|---|---|---|
| QuickPod RTX 4090 | ~$0.30–0.50/hr | $0.60–1.00 |
| DeepSeek V4-Flash | $0.14 in / $0.28 out per M tok | ~$0.02 |
| QuickPod storage (running) | bundled with compute | $0 |
| QuickPod storage (stopped) | **avoided by destroying** | $0 |
| B2 storage (20 GB) | ~$0.12/month | trivial |
| B2 egress on pod create | 20 GB × ~$0.01/GB | ~$0.20 |
| HF egress on first ever pod | free | $0 |
| **Total per session** | | **~$0.85–1.25** |

Per your guide: a 2×3090 (48 GB total) is usually cheaper per-hour than a 4090, and S2-Pro inference only needs ~17 GB.
