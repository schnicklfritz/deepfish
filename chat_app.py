"""
chat_app.py — Gradio chat: user prompt -> DeepSeek (with free-form S2-Pro tags)
-> Fish Speech S2-Pro voice clone -> wav.

All processing is local except DeepSeek (text only). No audio ever leaves the pod.
"""
import os, base64, time, pathlib
import gradio as gr
import requests
from openai import OpenAI

# ---------- config ----------
DS_KEY    = os.environ["DEEPSEEK_API_KEY"]
DS_MODEL  = os.environ.get("DEEPSEEK_MODEL", "deepseek-v4-flash")
FS_URL    = os.environ.get("FS_URL", "http://127.0.0.1:8080/v1/tts")
REF_AUDIO = os.environ.get("REFERENCE_AUDIO", "/workspace/references/voice.wav")
REF_TEXT  = os.environ.get("REFERENCE_TEXT", "")
OUT_DIR   = pathlib.Path(os.environ.get("OUT_DIR", "/workspace/outputs"))
CHAT_PORT = int(os.environ.get("CHAT_PORT", "7861"))
OUT_DIR.mkdir(parents=True, exist_ok=True)

# S2-Pro accepts FREE-FORM natural-language tags in [brackets].
# Place tag at the exact word where the shift should happen.
SYSTEM_PROMPT = """You reply as a conversational speaker for a voice-cloning TTS.

Use INLINE BRACKETED TAGS to control delivery. The TTS accepts free-form
descriptions in brackets, not a fixed enum. Examples of valid tags:
  [whisper]                                  — short presets work
  [the slow, measured cadence of someone tired]
  [a sudden burst of dark amusement]
  [pause]                                    — for beats and timing
  [quietly, almost to himself]
  [building intensity]

Rules:
- Tags go INLINE in the text, placed RIGHT BEFORE the phrase they modify.
  They affect what comes AFTER, not before.
- Use 2-5 tags per reply. Vary between short presets and rich descriptions.
- Don't narrate the tag in prose. Don't use parentheticals for stage directions.
- Keep replies under ~150 words (60s read-aloud).
- Write naturally; the tags do the heavy lifting on delivery.

Example of a good reply:
"[a wry chuckle] Yeah, I've thought about it. [pause] [quieter, more
reflective] Sometimes the only thing left is to keep walking and
[building] see what the road decides to give you."
"""

ds = OpenAI(api_key=DS_KEY, base_url="https://api.deepseek.com")

def deepseek_reply(history):
    msgs = [{"role": "system", "content": SYSTEM_PROMPT}] + history
    resp = ds.chat.completions.create(
        model=DS_MODEL, messages=msgs, stream=False, max_tokens=400,
    )
    return resp.choices[0].message.content.strip()

def synthesize(text):
    """POST tagged text + reference voice to Fish Speech. Returns wav path."""
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
    return str(out)

def respond(user_msg, history):
    history = history + [{"role": "user", "content": user_msg}]
    reply = deepseek_reply(history)
    history = history + [{"role": "assistant", "content": reply}]
    try:
        wav = synthesize(reply)
    except Exception as e:
        wav = None
        history[-1]["content"] += f"\n\n_(TTS error: {e})_"
    return history, wav, ""

with gr.Blocks(title="Fish-S2 × DeepSeek", analytics_enabled=False) as demo:
    gr.Markdown("# 🐟 Fish S2-Pro × DeepSeek\nFree-form tag chat → voice-cloned TTS.")
    chat  = gr.Chatbot(type="messages", height=420)
    audio = gr.Audio(label="Latest reply", autoplay=True)
    with gr.Row():
        txt  = gr.Textbox(placeholder="Say something…", scale=8, show_label=False)
        send = gr.Button("Send", scale=1, variant="primary")
    send.click(respond, [txt, chat], [chat, audio, txt])
    txt.submit(respond, [txt, chat], [chat, audio, txt])

if __name__ == "__main__":
    demo.queue().launch(
        server_name="0.0.0.0", server_port=CHAT_PORT, share=False,
    )
