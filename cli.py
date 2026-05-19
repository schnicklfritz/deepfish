#!/usr/bin/env python3
"""
cli.py — Terminal chat for Fish S2-Pro voice clone (streaming).
Usage:
  cli.py                                # REPL with default voice (morrison)
  cli.py --voice chong                  # REPL as Chong
  cli.py --voice chong "say something"  # one-shot
  cli.py --voice default "..."          # no voice clone
"""
import os, sys, time, pathlib, argparse
import requests
from openai import OpenAI

DS_KEY   = os.environ["DEEPSEEK_API_KEY"]
DS_MODEL = os.environ.get("DEEPSEEK_MODEL", "deepseek-v4-flash")
FS_URL   = os.environ.get("FS_URL", "http://127.0.0.1:8080/v1/tts")
OUT_DIR  = pathlib.Path(os.environ.get("OUT_DIR", "/workspace/outputs"))
AUDIO_FMT = os.environ.get("AUDIO_FORMAT", "wav")
OUT_DIR.mkdir(parents=True, exist_ok=True)

VOICES = {
    "morrison": "You speak as Jim Morrison — measured, poetic, declarative.",
    "chong":    "You speak as Tommy Chong — relaxed, philosophical, drawn-out cadence.",
    "default":  "You speak conversationally.",
}

def sys_prompt(voice):
    base = VOICES.get(voice, VOICES["default"])
    return (
        f"{base}\n\n"
        "Use inline bracketed emotive tags (free-form descriptions allowed): "
        "[whisper], [a slow chuckle], [building intensity], [pause], [reverent]. "
        "Place tags right before the phrase they modify. 2-5 tags per reply. "
        "No stage directions in prose. Max ~120 words."
    )

ds = OpenAI(api_key=DS_KEY, base_url="https://api.deepseek.com")

def llm(history, voice):
    r = ds.chat.completions.create(
        model=DS_MODEL,
        messages=[{"role": "system", "content": sys_prompt(voice)}] + history,
        max_tokens=400, stream=False,
    )
    return r.choices[0].message.content.strip()

def tts(text, voice):
    payload = {
        "text": text,
        "format": AUDIO_FMT,
        "streaming": True,
    }
    if voice != "default":
        payload["reference_id"] = voice
    out = OUT_DIR / f"reply_{voice}_{int(time.time())}.{AUDIO_FMT}"
    with requests.post(FS_URL, json=payload, stream=True, timeout=300) as r:
        r.raise_for_status()
        with open(out, "wb") as f:
            for chunk in r.iter_content(chunk_size=8192):
                if chunk:
                    f.write(chunk)
    return out

def run(prompt, history, voice):
    history.append({"role": "user", "content": prompt})
    reply = llm(history, voice)
    history.append({"role": "assistant", "content": reply})
    print(f"\n[{voice}] {reply}\n")
    wav = tts(reply, voice)
    print(f"[fish] {wav}\n")
    return history

if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("--voice", default="morrison", choices=list(VOICES))
    p.add_argument("prompt", nargs="*", help="single prompt; omit for REPL")
    args = p.parse_args()
    hist = []
    if args.prompt:
        run(" ".join(args.prompt), hist, args.voice)
    else:
        print(f"REPL [{args.voice}] — Ctrl-D to quit\n")
        try:
            while True:
                m = input("you> ").strip()
                if m:
                    hist = run(m, hist, args.voice)
        except (EOFError, KeyboardInterrupt):
            print("\nbye")
