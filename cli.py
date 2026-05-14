k#!/usr/bin/env python3
"""
cli.py — Terminal chat for Fish S2-Pro + DeepSeek voice clone.
Usage:
  python cli.py                      # interactive REPL
  python cli.py "say hello, darkly"  # one-shot
Outputs land in $OUT_DIR (default /workspace/outputs/).
"""
import os, sys, base64, time, pathlib, argparse
import requests
from openai import OpenAI

DS_KEY    = os.environ["DEEPSEEK_API_KEY"]
DS_MODEL  = os.environ.get("DEEPSEEK_MODEL", "deepseek-v4-flash")
FS_URL    = os.environ.get("FS_URL", "http://127.0.0.1:8080/v1/tts")
REF_AUDIO = os.environ.get("REFERENCE_AUDIO", "/workspace/references/voice.wav")
REF_TEXT  = os.environ.get("REFERENCE_TEXT", "")
OUT_DIR   = pathlib.Path(os.environ.get("OUT_DIR", "/workspace/outputs"))
OUT_DIR.mkdir(parents=True, exist_ok=True)

SYS = (
    "You reply as a conversational speaker for a voice-cloning TTS. "
    "Use inline bracketed tags to control delivery — free-form descriptions "
    "work: [whisper], [a slow, tired cadence], [pause], [building intensity], "
    "[a wry chuckle]. Place tags right before the phrase they modify. "
    "2-5 tags per reply. No stage directions in prose. Max ~150 words."
)

ds = OpenAI(api_key=DS_KEY, base_url="https://api.deepseek.com")

def llm(history):
    r = ds.chat.completions.create(
        model=DS_MODEL,
        messages=[{"role": "system", "content": SYS}] + history,
        max_tokens=400, stream=False,
    )
    return r.choices[0].message.content.strip()

def tts(text):
    payload = {"text": text, "format": "wav", "streaming": False}
    if pathlib.Path(REF_AUDIO).exists():
        with open(REF_AUDIO, "rb") as f:
            payload["references"] = [{
                "audio": base64.b64encode(f.read()).decode(),
                "text": REF_TEXT,
            }]
    r = requests.post(FS_URL, json=payload, timeout=300)
    r.raise_for_status()
    out = OUT_DIR / f"reply_{int(time.time())}.wav"
    out.write_bytes(r.content)
    return out

def run(prompt, history):
    history.append({"role": "user", "content": prompt})
    reply = llm(history)
    history.append({"role": "assistant", "content": reply})
    print(f"\n[deepseek] {reply}\n")
    wav = tts(reply)
    print(f"[fish] {wav}\n")
    return history

if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("prompt", nargs="*")
    args = p.parse_args()
    hist = []
    if args.prompt:
        run(" ".join(args.prompt), hist)
    else:
        print("REPL — Ctrl-D to quit\n")
        try:
            while True:
                m = input("you> ").strip()
                if m:
                    hist = run(m, hist)
        except (EOFError, KeyboardInterrupt):
            print("\nbye")
