# 1) Check how far along the current download is
ls -la /workspace/checkpoints/s2-pro/ 2>/dev/null
du -sh /workspace/checkpoints/s2-pro/ 2>/dev/null
# S2-Pro is ~15-20 GB total. If you're past ~5 GB, let it ride.

# 2) Also add HF_TOKEN to the QuickPod template env vars for future pods
#    (Settings → Edit Template → Environment Variables)
#    Key:   HF_TOKEN
#    Value: hf_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
#    Even without hf_transfer, the token gives better rate limits and unauths
#    against the once-an-hour anonymous quota.
