"""
chat_app.py — Gradio chat: user prompt → DeepSeek → Fish S2-Pro via reference_id.
Streaming download (faster perceived latency).
Voices must be registered via /v1/references/add before launch.
setup.sh auto-registers any /workspace/references/<id>.wav + <id>.txt pairs.
"""
import os, time, pathlib
import gradio as gr
import requests
from openai import OpenAI

# ---------- config ----------
DS_KEY    = os.environ["DEEPSEEK_API_KEY"]
DS_MODEL  = os.environ.get("DEEPSEEK_MODEL", "deepseek-v4-flash")
FS_URL    = os.environ.get("FS_URL", "http://127.0.0.1:8080/v1/tts")
OUT_DIR   = pathlib.Path(os.environ.get("OUT_DIR", "/workspace/outputs"))
CHAT_PORT = int(os.environ.get("CHAT_PORT", "7861"))
AUDIO_FMT = os.environ.get("AUDIO_FORMAT", "wav")    # 'wav' or 'mp3'
OUT_DIR.mkdir(parents=True, exist_ok=True)

VOICES = {
    "morrison": {
        "label": "Jim Morrison",
        "tag_hints": "[low and slow] [reverent] [quietly intense] [a half-smile in his voice] [building] [a sigh]",
        "persona": "You speak as Jim Morrison — measured, poetic, declarative. Lean into pauses.",
    },
    "chong": {
        "label": "Tommy Chong",
        "tag_hints": "[a slow chuckle starting] [philosophical] [trailing off, distracted] [mock-serious] [low and amused] [pause]",
        "persona": "You speak as Tommy Chong — relaxed, philosophical, drawn-out cadence, occasional warm laughter.",
    },
    "default": {
        "label": "Default voice (no clone)",
        "tag_hints": "[whisper] [excited] [pause] [emphasis] [a wry chuckle]",
        "persona": "You speak conversationally.",
    },
}

def build_system_prompt(voice_key: str) -> str:
    v = VOICES[voice_key]
    return f"""{v['persona']}

Use INLINE BRACKETED TAGS to control delivery. Free-form descriptions work
(this TTS accepts any natural-language tag). Mix short presets with rich ones.

Example tags that fit this voice:
{v['tag_hints']}

Rules:
- Tags go INLINE, RIGHT BEFORE the phrase they modify.
- 2-5 tags per reply. Vary between short and rich.
- Never narrate the tag. Never use parenthetical stage directions.
- Keep replies under ~120 words (60 sec read-aloud).
"""

ds = OpenAI(api_key=DS_KEY, base_url="https://api.deepseek.com")

def deepseek_reply(history, voice_key):
    msgs = [{"role": "system", "content": build_system_prompt(voice_key)}] + history
    r = ds.chat.completions.create(
        model=DS_MODEL, messages=msgs, max_tokens=400, stream=False,
    )
    return r.choices[0].message.content.strip()

def synthesize(text, voice_key):
    """POST to /v1/tts with streaming. Writes chunks as they arrive."""
    payload = {
        "text": text,
        "format": AUDIO_FMT,
        "streaming": True,        # ← time-to-first-byte improvement
    }
    if voice_key != "default":
        payload["reference_id"] = voice_key

    out = OUT_DIR / f"reply_{voice_key}_{int(time.time())}.{AUDIO_FMT}"
    with requests.post(FS_URL, json=payload, stream=True, timeout=300) as r:
        r.raise_for_status()
        with open(out, "wb") as f:
            for chunk in r.iter_content(chunk_size=8192):
                if chunk:
                    f.write(chunk)
    return str(out)

def respond(user_msg, history, voice_key):
    history = history + [{"role": "user", "content": user_msg}]
    reply = deepseek_reply(history, voice_key)
    history = history + [{"role": "assistant", "content": reply}]
    try:
        wav = synthesize(reply, voice_key)
    except Exception as e:
        wav = None
        history[-1]["content"] += f"\n\n_(TTS error: {e})_"
    return history, wav, ""

VOICE_CHOICES = [(v["label"], k) for k, v in VOICES.items()]

with gr.Blocks(title="Fish S2-Pro × DeepSeek", analytics_enabled=False) as demo:
    gr.Markdown("# 🐟 Fish S2-Pro × DeepSeek\nVoice-cloned chat with free-form emotive tags")
    with gr.Row():
        voice = gr.Dropdown(
            choices=VOICE_CHOICES, value="morrison",
            label="Voice", scale=2, interactive=True,
        )
    chat  = gr.Chatbot(type="messages", height=420)
    audio = gr.Audio(label="Latest reply", autoplay=True)
    with gr.Row():
        txt  = gr.Textbox(placeholder="Say something…", scale=8, show_label=False)
        send = gr.Button("Send", scale=1, variant="primary")
    send.click(respond, [txt, chat, voice], [chat, audio, txt])
    txt.submit(respond, [txt, chat, voice], [chat, audio, txt])

if __name__ == "__main__":
    demo.queue().launch(
        server_name="0.0.0.0", server_port=CHAT_PORT, share=False,
    )
