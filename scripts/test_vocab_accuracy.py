#!/usr/bin/env python3
"""
Type4Me Vocabulary ASR Accuracy Test

End-to-end TTS → ASR pipeline: generates speech from test sentences via
Volcengine TTS, sends audio to available ASR engines, scores target-word
accuracy.

Two sentence groups:
  - CTX  = AI-discussion context (gives ASR semantic clues)
  - BARE = casual/random context (ASR relies on acoustics alone)

Usage:
    python3 scripts/test_vocab_accuracy.py [options]

Options:
    --sv-port PORT     SenseVoice server port (auto-detects if omitted)
    --qwen3-port PORT  Qwen3-ASR server port (auto-detects if omitted)
    --no-volc          Skip Volcengine cloud ASR
    --no-cache         Regenerate all TTS audio
    --voice VOICE      Volcengine TTS voice (default: BV700_streaming)
    --tts-cluster CLU  TTS cluster: volcano_tts | volcano_icl (default: volcano_tts)
    --apply-snippets   Also show results after snippet correction
    --save FILE        Save detailed results to JSON
    --only ctx|bare    Only run one group
    --filter WORD      Only sentences targeting WORD (case-insensitive)

Requires: websockets

Volcengine TTS resources:
    seed-tts-1.0    豆包语音合成模型1.0
    seed-tts-2.0    豆包语音合成模型2.0 (更自然)

Speakers: see https://www.volcengine.com/docs/6561/1257544
"""

import argparse
import asyncio
import base64
import gzip
import json
import os
import re
import struct
import subprocess
import sys
import time
import uuid
from dataclasses import dataclass, asdict
from pathlib import Path
from urllib.request import urlopen, Request
from urllib.error import HTTPError

try:
    import websockets
except ImportError:
    sys.exit("Missing: pip install websockets")

# ━━ Constants ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

SAMPLE_RATE = 16000
CHUNK_SIZE = 6400  # 200ms @ 16kHz 16-bit mono
AUDIO_DIR = Path(__file__).parent / "test-vocab-audio"
CREDS_PATH = Path.home() / "Library/Application Support/Type4Me/credentials.json"
SNIPPETS_PATH = Path.home() / "Library/Application Support/Type4Me/builtin-snippets.json"
HOTWORDS_PATH = Path.home() / "Library/Application Support/Type4Me/builtin-hotwords.json"

# ASR
VOLC_ASR_URL = "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async"
VOLC_ASR_RESOURCE = "volc.seedasr.sauc.duration"

# TTS (V3 大模型语音合成)
VOLC_TTS_URL = "https://openspeech.bytedance.com/api/v3/tts/unidirectional"
VOLC_TTS_APPID = "6589448556"
VOLC_TTS_TOKEN = "DMODvsQHb3elsN7M-kLbVfb_xTapQcZH"
VOLC_TTS_RESOURCE = "seed-tts-1.0"  # or seed-tts-2.0

# ━━ Test Cases ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━


@dataclass
class Case:
    id: str
    text: str
    targets: list
    ctx: bool  # True = AI context, False = casual


CASES = [
    # ═══════════════════════════════════════════
    #  CTX: AI discussion (rich semantic context)
    #  句式偏向真实对话: "我用X做了Y", "X比Y强"
    # ═══════════════════════════════════════════

    # -- OpenAI reasoning models --
    Case("ctx_01", "o3比o1强不少但API价格也贵了三倍",
         ["o3", "o1"], True),
    Case("ctx_02", "预算有限就用o4-mini，性价比比o3-mini高",
         ["o4-mini", "o3-mini"], True),

    # -- vibe coding ecosystem --
    Case("ctx_03", "我最近都在vibe coding，用Lovable搭了个网站",
         ["vibe coding", "Lovable"], True),
    Case("ctx_04", "Bolt.new和v0哪个生成前端代码更靠谱",
         ["Bolt.new", "v0"], True),

    # -- Claude / Anthropic --
    Case("ctx_05", "Anthropic的Claude Code是目前最好的coding agent",
         ["Anthropic", "Claude Code"], True),

    # -- Models --
    Case("ctx_06", "DeepSeek R1的推理能力确实强，开源社区都在用",
         ["DeepSeek R1"], True),
    Case("ctx_07", "Gemini 3和Llama 4在多模态上打得很激烈",
         ["Gemini 3", "Llama 4"], True),
    Case("ctx_08", "Kimi K2的上下文窗口到了一百万token",
         ["Kimi K2"], True),
    Case("ctx_09", "Mixtral用的MoE架构所以推理速度快",
         ["Mixtral", "MoE"], True),
    Case("ctx_10", "Mistral最近发布了新版本，Grok 4也跟着出了",
         ["Mistral", "Grok 4"], True),

    # -- Chinese AI (拆开，不挤在一句) --
    Case("ctx_11", "Kimi和智谱在中文理解上比国外模型好不少",
         ["Kimi", "智谱"], True),
    Case("ctx_12", "月之暗面做的是Kimi，智谱做的是GLM",
         ["月之暗面", "GLM"], True),
    Case("ctx_13", "豆包和阶跃星辰算是国内第二梯队的代表",
         ["豆包", "阶跃星辰"], True),

    # -- Frameworks & tools --
    Case("ctx_14", "用LangGraph搭multi-agent工作流比直接写省事多了",
         ["LangGraph", "multi-agent"], True),
    Case("ctx_15", "Cursor的母公司Anysphere估值已经过百亿了",
         ["Cursor", "Anysphere"], True),
    Case("ctx_16", "Windsurf配合Cline来写代码效率提升很大",
         ["Windsurf", "Cline"], True),
    Case("ctx_17", "Cognition做的Devin是第一个AI软件工程师",
         ["Cognition", "Devin"], True),
    Case("ctx_18", "ElevenLabs的语音合成效果是目前最自然的",
         ["ElevenLabs"], True),
    Case("ctx_19", "Dify和Coze都能低代码搭AI应用，但设计理念不一样",
         ["Dify", "Coze"], True),

    # -- Concepts --
    Case("ctx_20", "用tiktoken算一下会不会超context window的限制",
         ["tiktoken", "context window"], True),
    Case("ctx_21", "chain of thought能显著提升LLM的推理表现",
         ["chain of thought", "LLM"], True),
    Case("ctx_22", "A2A协议和MCP协议是AI agent互通的两大标准",
         ["A2A", "MCP"], True),
    Case("ctx_23", "用LoRA做fine-tuning只需要很少的数据就够了",
         ["LoRA", "fine-tuning"], True),
    Case("ctx_24", "现在很多模型用DPO替代RLHF来做对齐训练",
         ["DPO", "RLHF"], True),
    Case("ctx_25", "做RAG的话向量数据库推荐用Pinecone或者Qdrant",
         ["RAG", "Pinecone", "Qdrant"], True),

    # -- Hardware --
    Case("ctx_26", "NVIDIA的Blackwell架构比H100性能强好几倍",
         ["Blackwell", "H100", "NVIDIA"], True),

    # -- Creative AI --
    Case("ctx_27", "FLUX出图质量已经超过Midjourney了",
         ["FLUX", "Midjourney"], True),
    Case("ctx_28", "Veo 3的视频生成效果和Sora 2各有千秋",
         ["Veo 3", "Sora 2"], True),

    # -- Other tools --
    Case("ctx_29", "Hugging Face上开源模型越来越多，用Ollama本地跑很方便",
         ["Hugging Face", "Ollama"], True),
    Case("ctx_30", "前端部署到Vercel，后端用Supabase，省事很多",
         ["Vercel", "Supabase"], True),

    # ═══════════════════════════════════════════
    #  BARE: casual / random context
    #  句式偏日常: 提问、闲聊、请求帮忙
    # ═══════════════════════════════════════════

    # -- 重点词必须在 BARE 也出现 --
    Case("bare_01", "帮我查一下o3怎么收费的",
         ["o3"], False),
    Case("bare_02", "o4-mini和o3-mini有什么区别",
         ["o4-mini", "o3-mini"], False),
    Case("bare_03", "今天试了一下vibe coding还挺有意思",
         ["vibe coding"], False),
    Case("bare_04", "我朋友推荐了一个叫Lovable的东西",
         ["Lovable"], False),
    Case("bare_05", "帮我看看Bolt.new上面那个模板",
         ["Bolt.new"], False),
    Case("bare_06", "你知道Anthropic吗就是做Claude的那家",
         ["Anthropic", "Claude"], False),
    Case("bare_07", "DeepSeek R1可以本地跑吗",
         ["DeepSeek R1"], False),
    Case("bare_08", "Kimi可以免费用吗",
         ["Kimi"], False),
    Case("bare_09", "那个Mixtral模型支持中文吗",
         ["Mixtral"], False),
    Case("bare_10", "那个叫LangGraph的框架要怎么安装",
         ["LangGraph"], False),
    Case("bare_11", "我在Cursor里面装了Cline这个插件",
         ["Cursor", "Cline"], False),
    Case("bare_12", "有人用过ElevenLabs吗效果怎么样",
         ["ElevenLabs"], False),
    Case("bare_13", "帮我在Dify上面配一个工作流",
         ["Dify"], False),
    Case("bare_14", "你听说过A2A协议吗",
         ["A2A"], False),
    Case("bare_15", "tiktoken这个库怎么装",
         ["tiktoken"], False),
    Case("bare_16", "我想买一张Blackwell架构的显卡",
         ["Blackwell"], False),
    Case("bare_17", "FLUX和Midjourney到底哪个好用",
         ["FLUX", "Midjourney"], False),
    Case("bare_18", "智谱是哪家公司做的",
         ["智谱"], False),
    Case("bare_19", "阶跃星辰最近有什么新模型出来",
         ["阶跃星辰"], False),
    Case("bare_20", "Devin好像很贵要五百美金一个月",
         ["Devin"], False),
]

# ━━ TTS (Volcengine V3 大模型) ━━━━━━━━━━━━━━━━━━━━━━━━━━


def _pcm_to_wav(pcm: bytes, rate: int = SAMPLE_RATE) -> bytes:
    """Add WAV header to raw PCM16-LE data."""
    n = len(pcm)
    return struct.pack(
        "<4sI4s4sIHHIIHH4sI",
        b"RIFF", 36 + n, b"WAVE",
        b"fmt ", 16, 1, 1,              # PCM, mono
        rate, rate * 2, 2, 16,           # 16-bit
        b"data", n,
    ) + pcm


def tts_generate(text: str, wav_path: Path, voice: str,
                 resource_id: str = VOLC_TTS_RESOURCE):
    """Volcengine V3 TTS HTTP Chunked → PCM → WAV file (16kHz mono)."""
    body = json.dumps({
        "user": {"uid": "type4me_test"},
        "req_params": {
            "text": text,
            "speaker": voice,
            "audio_params": {
                "format": "pcm",
                "sample_rate": SAMPLE_RATE,
            },
        },
    }).encode()

    req = Request(
        VOLC_TTS_URL,
        data=body,
        headers={
            "Content-Type": "application/json",
            "X-Api-App-Id": VOLC_TTS_APPID,
            "X-Api-Access-Key": VOLC_TTS_TOKEN,
            "X-Api-Resource-Id": resource_id,
        },
    )
    try:
        with urlopen(req, timeout=60) as resp:
            raw = resp.read().decode("utf-8", errors="replace")
    except HTTPError as e:
        raise RuntimeError(f"TTS API {e.code}: {e.read().decode()[:300]}")

    audio_parts = []
    for line in raw.strip().split("\n"):
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            continue
        code = obj.get("code")
        if code == 0 and obj.get("data"):
            audio_parts.append(base64.b64decode(obj["data"]))
        elif code == 20000000:
            break
        elif code and code not in (0, 20000000):
            raise RuntimeError(
                f"TTS error: code={code} msg={obj.get('message')}"
            )

    if not audio_parts:
        raise RuntimeError("TTS returned no audio data")

    pcm = b"".join(audio_parts)
    with open(wav_path, "wb") as f:
        f.write(_pcm_to_wav(pcm))


def wav_to_pcm(wav_path: Path) -> bytes:
    """WAV → raw PCM16-LE bytes (parse WAV header, ffmpeg fallback)."""
    with open(wav_path, "rb") as f:
        data = f.read()

    # Find "data" chunk in WAV
    idx = data.find(b"data")
    if idx >= 0 and idx + 8 <= len(data):
        chunk_size = struct.unpack_from("<I", data, idx + 4)[0]
        return data[idx + 8:idx + 8 + chunk_size]

    # Fallback
    r = subprocess.run(
        ["ffmpeg", "-y", "-i", str(wav_path), "-ar", str(SAMPLE_RATE),
         "-ac", "1", "-f", "s16le", "-acodec", "pcm_s16le", "pipe:1"],
        capture_output=True,
    )
    if r.returncode != 0:
        raise RuntimeError(f"ffmpeg: {r.stderr.decode()[:200]}")
    return r.stdout


# ━━ Volcengine Binary Protocol ━━━━━━━━━━━━━━━━━━━━━━━━━━━


def _volc_msg(mt, fl, sr, co, payload):
    hdr = bytes([(1 << 4) | 1, (mt << 4) | (fl & 0xF), (sr << 4) | (co & 0xF), 0])
    return hdr + struct.pack(">I", len(payload)) + payload


def _volc_req(uid, hotwords=None):
    req = {
        "model_name": "bigmodel", "enable_punc": True, "enable_ddc": True,
        "enable_nonstream": True, "show_utterances": True, "result_type": "full",
        "end_window_size": 3000, "force_to_speech_time": 1000,
    }
    if hotwords:
        hw_list = hotwords if isinstance(hotwords, list) else hotwords.get("words", [])
        hw_scale = hotwords.get("scale", 5.0) if isinstance(hotwords, dict) else 5.0
        hw = [w.strip() for w in hw_list if w.strip()]
        if hw:
            req["context"] = json.dumps(
                {"hotwords": [{"word": w, "scale": hw_scale} for w in hw]}
            )
    return json.dumps({
        "user": {"uid": uid},
        "audio": {"format": "pcm", "codec": "raw",
                  "rate": SAMPLE_RATE, "bits": 16, "channel": 1},
        "request": req,
    }).encode()


def _volc_audio(pcm, last):
    return _volc_msg(2, 2 if last else 0, 0, 0, pcm)


def _volc_parse(data):
    if len(data) < 4:
        return None
    mt = (data[1] >> 4) & 0xF
    fl = data[1] & 0xF
    sr = (data[2] >> 4) & 0xF
    co = data[2] & 0xF
    off = (data[0] & 0xF) * 4
    if fl in (1, 3):
        off += 4
    if len(data) < off + 4:
        return None
    sz = struct.unpack(">I", data[off:off + 4])[0]
    off += 4
    if len(data) < off + sz:
        return None
    p = data[off:off + sz]
    if mt == 0xF:
        return {"_error": True}
    if co == 1:
        p = gzip.decompress(p)
    if sr == 1 and p:
        return json.loads(p)
    return None


# ━━ ASR Engines ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━


async def asr_volc(pcm, app_key, access_key, resource_id, hotwords=None):
    """Volcengine Seed ASR (cloud, streaming WebSocket)."""
    uid = f"t-{uuid.uuid4().hex[:8]}"
    hdrs = {
        "X-Api-App-Key": app_key,
        "X-Api-Access-Key": access_key,
        "X-Api-Resource-Id": resource_id,
        "X-Api-Connect-Id": str(uuid.uuid4()),
    }
    async with websockets.connect(VOLC_ASR_URL, additional_headers=hdrs) as ws:
        await ws.send(_volc_msg(1, 0, 1, 0, _volc_req(uid, hotwords)))
        o = 0
        while o < len(pcm):
            c = pcm[o:o + CHUNK_SIZE]
            last = o + CHUNK_SIZE >= len(pcm)
            await ws.send(_volc_audio(c, last))
            o += CHUNK_SIZE
            if not last:
                await asyncio.sleep(0.08)

        txt = ""
        try:
            while True:
                m = await asyncio.wait_for(ws.recv(), timeout=15)
                if isinstance(m, bytes):
                    p = _volc_parse(m)
                    if not p:
                        continue
                    if p.get("_error"):
                        break
                    r = p.get("result", p)
                    t = r.get("text", "")
                    if t:
                        txt = t
                    us = r.get("utterances", [])
                    d = [u["text"] for u in us if u.get("definite")]
                    if d:
                        txt = "".join(d)
        except (asyncio.TimeoutError, websockets.exceptions.ConnectionClosed):
            pass
    return txt.strip()


async def asr_local(pcm, port, timeout=30):
    """Local ASR via WebSocket (SenseVoice or Qwen3-ASR, same protocol)."""
    try:
        async with websockets.connect(f"ws://127.0.0.1:{port}/ws") as ws:
            o = 0
            while o < len(pcm):
                await ws.send(pcm[o:o + CHUNK_SIZE])
                o += CHUNK_SIZE
                await asyncio.sleep(0.05)
            await ws.send(b"")

            txt = ""
            try:
                while True:
                    m = await asyncio.wait_for(ws.recv(), timeout=timeout)
                    d = json.loads(m)
                    if d.get("text"):
                        txt = d["text"]
                    if d.get("is_final") or d.get("type") == "completed":
                        break
            except (asyncio.TimeoutError, websockets.exceptions.ConnectionClosed):
                pass
            return txt.strip()
    except (ConnectionRefusedError, OSError):
        return None


async def asr_deepgram(pcm, api_key, model="nova-3", hotwords=None,
                      language="zh"):
    """Deepgram streaming ASR."""
    from urllib.parse import quote
    params = (f"model={model}&language={language}&encoding=linear16"
              f"&sample_rate={SAMPLE_RATE}&channels=1"
              f"&punctuate=true&smart_format=true")
    if hotwords:
        ws = hotwords.get("words", hotwords) if isinstance(hotwords, dict) else hotwords
        ascii_hw = [w for w in ws if w.isascii()][:30]
        # nova-3 uses keyterm, older models use keywords
        param_name = "keyterm" if "nova-3" in model else "keywords"
        for w in ascii_hw:
            params += f"&{param_name}={quote(w)}"
    url = f"wss://api.deepgram.com/v1/listen?{params}"
    hdrs = {"Authorization": f"Token {api_key}"}

    async with websockets.connect(url, additional_headers=hdrs) as ws:
        o = 0
        while o < len(pcm):
            await ws.send(pcm[o:o + CHUNK_SIZE])
            o += CHUNK_SIZE
            await asyncio.sleep(0.05)
        await ws.send(json.dumps({"type": "CloseStream"}))

        parts = []
        try:
            while True:
                m = await asyncio.wait_for(ws.recv(), timeout=15)
                d = json.loads(m)
                if d.get("type") == "Results":
                    alt = d.get("channel", {}).get("alternatives", [{}])
                    t = alt[0].get("transcript", "") if alt else ""
                    if t and (d.get("is_final") or d.get("speech_final")):
                        parts.append(t)
        except (asyncio.TimeoutError, websockets.exceptions.ConnectionClosed):
            pass
    return " ".join(parts).strip()


def asr_openai_sync(pcm, api_key, model="gpt-4o-transcribe", base_url=None):
    """OpenAI transcription API (HTTP batch, non-streaming)."""
    wav = _pcm_to_wav(pcm)
    base = (base_url or "https://api.openai.com/v1").rstrip("/")
    # Avoid double /v1 if baseURL already includes it
    if base.endswith("/v1"):
        url = base + "/audio/transcriptions"
    else:
        url = base + "/v1/audio/transcriptions"
    boundary = uuid.uuid4().hex
    body = (
        f"--{boundary}\r\n"
        f'Content-Disposition: form-data; name="file"; filename="a.wav"\r\n'
        f"Content-Type: audio/wav\r\n\r\n"
    ).encode() + wav + (
        f"\r\n--{boundary}\r\n"
        f'Content-Disposition: form-data; name="model"\r\n\r\n'
        f"{model}\r\n"
        f"--{boundary}\r\n"
        f'Content-Disposition: form-data; name="response_format"\r\n\r\n'
        f"json\r\n"
        f"--{boundary}--\r\n"
    ).encode()
    req = Request(url, data=body, headers={
        "Authorization": f"Bearer {api_key}",
        "Content-Type": f"multipart/form-data; boundary={boundary}",
    })
    with urlopen(req, timeout=60) as resp:
        result = json.loads(resp.read())
    return result.get("text", "").strip()


async def asr_assemblyai(pcm, api_key, model="universal-streaming-multilingual",
                         hotwords=None):
    """AssemblyAI V3 streaming ASR."""
    url = (f"wss://streaming.assemblyai.com/v3/ws"
           f"?sample_rate={SAMPLE_RATE}&encoding=pcm_s16le"
           f"&speech_model={model}&format_turns=true")
    hdrs = {"Authorization": api_key}

    async with websockets.connect(url, additional_headers=hdrs) as ws:
        begin = json.loads(await asyncio.wait_for(ws.recv(), timeout=10))
        if begin.get("type") != "Begin":
            return f"[AssemblyAI: expected Begin, got {begin.get('type')}]"

        if hotwords:
            wl = hotwords.get("words", hotwords) if isinstance(hotwords, dict) else hotwords
            await ws.send(json.dumps({
                "type": "UpdateConfiguration",
                "keyterms_prompt": wl[:100],
            }))

        o = 0
        while o < len(pcm):
            await ws.send(pcm[o:o + CHUNK_SIZE])
            o += CHUNK_SIZE
            await asyncio.sleep(0.05)
        await ws.send(json.dumps({"type": "Terminate"}))

        turns = {}
        try:
            while True:
                m = await asyncio.wait_for(ws.recv(), timeout=15)
                d = json.loads(m)
                if d.get("type") == "Turn":
                    turns[d.get("turn_order", 0)] = d.get("transcript", "")
                elif d.get("type") == "Termination":
                    break
        except (asyncio.TimeoutError, websockets.exceptions.ConnectionClosed):
            pass
    return " ".join(turns[k] for k in sorted(turns)).strip()


async def asr_soniox(pcm, api_key, model="stt-rt-v4", hotwords=None):
    """Soniox streaming ASR."""
    url = "wss://stt-rt.soniox.com/transcribe-websocket"

    async with websockets.connect(url, ping_interval=None) as ws:
        init = {
            "api_key": api_key, "model": model,
            "audio_format": "pcm_s16le",
            "sample_rate": SAMPLE_RATE, "num_channels": 1,
            "enable_endpoint_detection": True,
        }
        if hotwords:
            wl = hotwords.get("words", hotwords) if isinstance(hotwords, dict) else hotwords
            ascii_hw = [w for w in wl if w.isascii()][:100]
            if ascii_hw:
                init["context"] = {"terms": ascii_hw}
        await ws.send(json.dumps(init))

        # Wait for server to acknowledge init (Soniox validates API key here)
        try:
            ack = await asyncio.wait_for(ws.recv(), timeout=5)
            d = json.loads(ack)
            if d.get("error_code"):
                return f"[Soniox: {d.get('error_message')}]"
        except asyncio.TimeoutError:
            pass  # Some versions don't send ack

        # Send audio
        o = 0
        while o < len(pcm):
            await ws.send(pcm[o:o + CHUNK_SIZE])
            o += CHUNK_SIZE
            await asyncio.sleep(0.05)

        # Finalize
        await ws.send(json.dumps({"type": "finalize", "trailing_silence_ms": 500}))

        # Collect results
        confirmed = []
        try:
            while True:
                m = await asyncio.wait_for(ws.recv(), timeout=15)
                d = json.loads(m)
                if d.get("error_code"):
                    return f"[Soniox: {d.get('error_message')}]"
                for tok in d.get("tokens", []):
                    t = tok.get("text", "")
                    if tok.get("is_final") and t not in ("<end>", "<fin>"):
                        confirmed.append(t)
                if d.get("finished"):
                    break
        except (asyncio.TimeoutError, websockets.exceptions.ConnectionClosed):
            pass
    return "".join(confirmed).strip()


# ━━ Snippet Replacement ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━


def load_snippets():
    """Load builtin snippet corrections."""
    if not SNIPPETS_PATH.exists():
        return []
    with open(SNIPPETS_PATH) as f:
        return json.load(f)


def _flex_pat(trigger):
    """Build space-insensitive regex (mirrors Swift buildFlexPattern)."""
    s = "".join(trigger.split())
    core = r"\s*".join(re.escape(c) for c in s)
    return r"(?<![a-zA-Z0-9])" + core + r"(?![a-zA-Z0-9])"


def apply_snippets(text, snippets):
    """Apply all snippet corrections to text."""
    for s in snippets:
        t, r = s.get("trigger", ""), s.get("replacement", "")
        if not t or not r:
            continue
        try:
            text = re.sub(_flex_pat(t), r, text, flags=re.IGNORECASE)
        except re.error:
            pass
    return text


# ━━ Scoring ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━


def score(text, targets):
    """Check which target words appear in ASR output. Returns {target: bool}."""
    results = {}
    for t in targets:
        tn = t.lower().replace("-", "").replace(" ", "").replace(".", "")
        an = text.lower().replace("-", "").replace(" ", "").replace(".", "")
        results[t] = tn in an
    return results


def fmt_score(sc):
    return "  ".join(f"{'✓' if ok else '✗'} {t}" for t, ok in sc.items())


# ━━ Port Detection ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━


def check_port(port):
    """Check if an ASR server responds on this port."""
    import socket
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(0.3)
        result = s.connect_ex(("127.0.0.1", port))
        s.close()
        return result == 0
    except Exception:
        return False


def detect_ports():
    """Scan common ports for local ASR servers."""
    found = []
    for p in range(10095, 10105):
        if check_port(p):
            found.append(p)
    sv = found[0] if len(found) >= 1 else None
    q3 = found[1] if len(found) >= 2 else None
    return sv, q3


# ━━ Display Helpers ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━


W = 74  # output width


def banner(title):
    print(f"\n{'=' * W}")
    print(f"  {title}")
    print(f"{'=' * W}")


def divider():
    print(f"{'─' * W}")


# ━━ Main ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━


async def main():
    p = argparse.ArgumentParser(description="Type4Me Vocabulary ASR Accuracy Test")
    p.add_argument("--sv-port", type=int, help="SenseVoice port")
    p.add_argument("--qwen3-port", type=int, help="Qwen3-ASR port")
    p.add_argument("--no-volc", action="store_true", help="Skip Volcengine")
    p.add_argument("--no-cache", action="store_true", help="Regenerate TTS audio")
    p.add_argument("--voice", default="zh_female_shuangkuaisisi_moon_bigtts",
                    help="TTS speaker ID (default: 双快丝丝)")
    p.add_argument("--tts-resource", default=VOLC_TTS_RESOURCE,
                    help="TTS resource: seed-tts-1.0 | seed-tts-2.0")
    p.add_argument("--apply-snippets", action="store_true",
                    help="Show snippet-corrected results")
    p.add_argument("--save", type=str, help="Save results JSON")
    p.add_argument("--only", choices=["ctx", "bare"], help="Filter by group")
    p.add_argument("--filter", type=str, help="Filter by target word")
    p.add_argument("--scale", type=float, default=5.0,
                    help="Hotword boost scale for Volcengine (default: 5.0)")
    p.add_argument("--extra-hotwords", type=str,
                    help="Comma-separated extra hotwords to add")
    p.add_argument("--engines", type=str,
                    help="Comma-separated engine names to run (e.g. Volcengine,OpenAI)")
    p.add_argument("--no-hotwords", action="store_true",
                    help="Disable hotword boosting entirely")
    args = p.parse_args()

    # -- Filter cases --
    cases = list(CASES)
    if args.only == "ctx":
        cases = [c for c in cases if c.ctx]
    elif args.only == "bare":
        cases = [c for c in cases if not c.ctx]
    if args.filter:
        f = args.filter.lower()
        cases = [c for c in cases if any(f in t.lower() for t in c.targets)]
    if not cases:
        sys.exit("No test cases match your filter.")

    # -- Detect engines --
    engines = []
    eng_cfg = {}  # engine_name -> config dict

    creds = {}
    if CREDS_PATH.exists():
        creds = json.load(open(CREDS_PATH))

    # Volcengine
    if not args.no_volc:
        vc = creds.get("tf_asr_volcano", {})
        ak, sk = vc.get("appKey", ""), vc.get("accessKey", "")
        ri = vc.get("resourceId", "auto")
        if ri in ("", "auto"):
            ri = VOLC_ASR_RESOURCE
        if ak and sk:
            engines.append("Volcengine")
            eng_cfg["Volcengine"] = {"appKey": ak, "accessKey": sk, "resourceId": ri}

    # Deepgram
    dg = creds.get("tf_asr_deepgram", {})
    if dg.get("apiKey"):
        engines.append("Deepgram")
        eng_cfg["Deepgram"] = dg

    # OpenAI
    oai = creds.get("tf_asr_openai", {})
    if oai.get("apiKey"):
        engines.append("OpenAI")
        eng_cfg["OpenAI"] = oai

    # AssemblyAI
    aai = creds.get("tf_asr_assemblyai", {})
    if aai.get("apiKey"):
        engines.append("AssemblyAI")
        eng_cfg["AssemblyAI"] = aai

    # Soniox
    sox = creds.get("tf_asr_soniox", {})
    if sox.get("apiKey"):
        engines.append("Soniox")
        eng_cfg["Soniox"] = sox

    # Local servers
    sv_port = args.sv_port
    q3_port = args.qwen3_port
    if sv_port is None or q3_port is None:
        print("  Detecting local ASR servers...", end="", flush=True)
        det_sv, det_q3 = detect_ports()
        if sv_port is None:
            sv_port = det_sv
        if q3_port is None:
            q3_port = det_q3
        print(" done.")
    if sv_port:
        engines.append(f"SenseVoice(:{sv_port})")
    if q3_port:
        engines.append(f"Qwen3(:{q3_port})")

    # Filter engines if --engines specified
    if args.engines:
        allowed = {e.strip() for e in args.engines.split(",")}
        engines = [e for e in engines if e in allowed]

    if not engines:
        sys.exit("No ASR engines available. Check credentials.json or start local servers.")

    # Hotwords
    hotwords = None
    if not args.no_hotwords:
        hw_words = []
        if HOTWORDS_PATH.exists():
            hw_words = json.load(open(HOTWORDS_PATH))
        if args.extra_hotwords:
            for w in args.extra_hotwords.split(","):
                w = w.strip()
                if w and w not in hw_words:
                    hw_words.append(w)
        hotwords = {"words": hw_words, "scale": args.scale} if hw_words else None

    # Snippets
    snippets = load_snippets() if args.apply_snippets else []

    # -- Header --
    n_ctx = sum(1 for c in cases if c.ctx)
    n_bare = sum(1 for c in cases if not c.ctx)
    banner("Type4Me Vocabulary ASR Accuracy Test")
    print(f"  Engines:    {' | '.join(engines)}")
    print(f"  TTS Voice:  {args.voice} ({args.tts_resource})")
    print(f"  Cases:      {len(cases)} total ({n_ctx} ctx + {n_bare} bare)")
    if hotwords:
        print(f"  Hotwords:   {len(hotwords['words'])} loaded (scale={args.scale})")
    if snippets:
        print(f"  Snippets:   {len(snippets)} loaded (post-correction)")
    print(f"{'=' * W}")

    # -- Phase 1: Generate TTS audio --
    AUDIO_DIR.mkdir(exist_ok=True)
    gen_count = 0
    for c in cases:
        wav = AUDIO_DIR / f"{c.id}.wav"
        if wav.exists() and not args.no_cache:
            continue
        gen_count += 1

    if gen_count > 0:
        print(f"\n  Generating {gen_count} TTS audio files...")
        idx = 0
        for c in cases:
            wav = AUDIO_DIR / f"{c.id}.wav"
            if wav.exists() and not args.no_cache:
                continue
            idx += 1
            print(f"    [{idx}/{gen_count}] {c.id}: {c.text[:45]}...")
            tts_generate(c.text, wav, args.voice, args.tts_resource)
        print(f"  Audio cached in {AUDIO_DIR.relative_to(Path(__file__).parent.parent)}/")
    else:
        print(f"\n  All TTS audio cached. Use --no-cache to regenerate.")

    # -- Phase 2: Run ASR --
    all_results = []
    stats = {e: {"hits": 0, "total": 0} for e in engines}
    stats_ctx = {e: {"hits": 0, "total": 0} for e in engines}
    stats_bare = {e: {"hits": 0, "total": 0} for e in engines}
    stats_corrected = {e: {"hits": 0, "total": 0} for e in engines}

    for i, c in enumerate(cases):
        wav = AUDIO_DIR / f"{c.id}.wav"
        if not wav.exists():
            print(f"\n  [SKIP] {c.id}: audio file missing")
            continue

        pcm = wav_to_pcm(wav)
        dur = len(pcm) / (SAMPLE_RATE * 2)
        tag = "CTX " if c.ctx else "BARE"

        print(f"\n── [{i + 1}/{len(cases)}] {c.id} [{tag}] ({dur:.1f}s) ──")
        print(f"  Text:    {c.text}")
        print(f"  Target:  {', '.join(c.targets)}")
        divider()

        result = {
            "id": c.id, "text": c.text,
            "targets": c.targets, "ctx": c.ctx,
            "engines": {},
        }

        for eng in engines:
            cfg = eng_cfg.get(eng, {})
            t0 = time.monotonic()
            try:
                if eng == "Volcengine":
                    raw = await asr_volc(pcm, cfg["appKey"], cfg["accessKey"],
                                         cfg["resourceId"], hotwords)
                elif eng == "Deepgram":
                    raw = await asr_deepgram(pcm, cfg["apiKey"],
                                             cfg.get("model", "nova-3"), hotwords,
                                             cfg.get("language", "zh"))
                elif eng == "OpenAI":
                    raw = asr_openai_sync(pcm, cfg["apiKey"],
                                          cfg.get("model", "gpt-4o-transcribe"),
                                          cfg.get("baseURL"))
                elif eng == "AssemblyAI":
                    raw = await asr_assemblyai(pcm, cfg["apiKey"],
                                               cfg.get("model",
                                                        "universal-streaming-multilingual"),
                                               hotwords)
                elif eng == "Soniox":
                    raw = await asr_soniox(pcm, cfg["apiKey"],
                                           cfg.get("model", "stt-rt-v4"), hotwords)
                elif eng.startswith("SenseVoice"):
                    raw = await asr_local(pcm, sv_port, timeout=30)
                elif eng.startswith("Qwen3"):
                    raw = await asr_local(pcm, q3_port, timeout=60)
                else:
                    raw = None
            except Exception as e:
                raw = f"[ERROR: {e}]"

            elapsed = time.monotonic() - t0

            if raw is None:
                print(f"  {eng}: [server not responding]")
                continue

            sc = score(raw, c.targets)
            hits = sum(v for v in sc.values())
            print(f"  {eng} ({elapsed:.1f}s):")
            print(f"    ASR: {raw}")
            print(f"    {fmt_score(sc)}  ({hits}/{len(sc)})")

            # Update stats
            stats[eng]["hits"] += hits
            stats[eng]["total"] += len(sc)
            bucket = stats_ctx if c.ctx else stats_bare
            bucket[eng]["hits"] += hits
            bucket[eng]["total"] += len(sc)

            eng_result = {"raw": raw, "score": sc, "time": round(elapsed, 2)}

            # Snippet correction
            if snippets:
                corrected = apply_snippets(raw, snippets)
                if corrected != raw:
                    sc2 = score(corrected, c.targets)
                    hits2 = sum(v for v in sc2.values())
                    print(f"    Corrected: {corrected}")
                    print(f"    {fmt_score(sc2)}  ({hits2}/{len(sc2)})")
                    eng_result["corrected"] = corrected
                    eng_result["score_corrected"] = sc2
                    stats_corrected[eng]["hits"] += hits2
                    stats_corrected[eng]["total"] += len(sc2)
                else:
                    stats_corrected[eng]["hits"] += hits
                    stats_corrected[eng]["total"] += len(sc)

            result["engines"][eng] = eng_result
        all_results.append(result)

    # -- Phase 3: Summary --
    banner("SUMMARY")

    for eng in engines:
        s = stats[eng]
        sc = stats_ctx[eng]
        sb = stats_bare[eng]
        scr = stats_corrected[eng]
        if s["total"] == 0:
            continue

        pct = s["hits"] / s["total"] * 100
        print(f"\n  {eng}:")
        print(f"    Overall:  {s['hits']:3d}/{s['total']}  ({pct:.0f}%)")
        if sc["total"] > 0:
            print(f"    Context:  {sc['hits']:3d}/{sc['total']}  "
                  f"({sc['hits'] / sc['total'] * 100:.0f}%)")
        if sb["total"] > 0:
            print(f"    Bare:     {sb['hits']:3d}/{sb['total']}  "
                  f"({sb['hits'] / sb['total'] * 100:.0f}%)")
        if snippets and scr["total"] > 0:
            pct2 = scr["hits"] / scr["total"] * 100
            delta = scr["hits"] - s["hits"]
            sign = "+" if delta >= 0 else ""
            print(f"    + Snippets: {scr['hits']:3d}/{scr['total']}  "
                  f"({pct2:.0f}%, {sign}{delta})")

    # Most-missed targets
    print(f"\n  ── Most Missed Targets ──")
    miss_count = {}
    for r in all_results:
        for eng, data in r["engines"].items():
            for t, ok in data.get("score", {}).items():
                if not ok:
                    key = t
                    miss_count[key] = miss_count.get(key, 0) + 1
    if miss_count:
        for t, cnt in sorted(miss_count.items(), key=lambda x: -x[1])[:20]:
            bar = "█" * cnt
            print(f"    {cnt:2d}x  {t:20s}  {bar}")
    else:
        print(f"    All targets hit!")

    # Words that context helps
    print(f"\n  ── Context Effect (words recognized in CTX but not BARE) ──")
    ctx_only = {}
    bare_only = {}
    for r in all_results:
        for eng, data in r["engines"].items():
            for t, ok in data.get("score", {}).items():
                key = (eng, t)
                if r["ctx"]:
                    if ok:
                        ctx_only.setdefault(t, set()).add(eng)
                else:
                    if ok:
                        bare_only.setdefault(t, set()).add(eng)

    ctx_advantage = set()
    for t in ctx_only:
        if t not in bare_only:
            ctx_advantage.add(t)
    if ctx_advantage:
        for t in sorted(ctx_advantage):
            print(f"    CTX only: {t}")
    else:
        print(f"    No significant context effect detected.")

    print()

    # -- Save results --
    if args.save:
        # Convert score dicts (which have non-string values) properly
        save_data = []
        for r in all_results:
            rd = dict(r)
            rd["engines"] = {}
            for eng, data in r["engines"].items():
                ed = dict(data)
                # Convert score dicts to serializable format
                if "score" in ed:
                    ed["score"] = {k: v for k, v in ed["score"].items()}
                if "score_corrected" in ed:
                    ed["score_corrected"] = {k: v for k, v in ed["score_corrected"].items()}
                rd["engines"][eng] = ed
            save_data.append(rd)

        with open(args.save, "w") as f:
            json.dump(save_data, f, ensure_ascii=False, indent=2)
        print(f"  Results saved to {args.save}")
        print()


if __name__ == "__main__":
    asyncio.run(main())
