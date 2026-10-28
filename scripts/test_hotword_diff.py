#!/usr/bin/env python3
"""Compare SenseVoice recognition with and without hotwords."""
import asyncio
import json
import struct
import sys
from pathlib import Path

try:
    import websockets
except ImportError:
    sys.exit("pip install websockets")

AUDIO_DIR = Path(__file__).parent / "test-vocab-audio"
CHUNK_SIZE = 6400

CASES = [
    ("ctx_01", "o3比o1强不少但API价格也贵了三倍", ["o3", "o1"]),
    ("ctx_02", "预算有限就用o4-mini，性价比比o3-mini高", ["o4-mini", "o3-mini"]),
    ("ctx_03", "我最近都在vibe coding，用Lovable搭了个网站", ["vibe coding", "Lovable"]),
    ("ctx_04", "Bolt.new和v0哪个生成前端代码更靠谱", ["Bolt.new", "v0"]),
    ("ctx_05", "Anthropic的Claude Code是目前最好的coding agent", ["Anthropic", "Claude Code"]),
    ("ctx_06", "DeepSeek R1的推理能力确实强，开源社区都在用", ["DeepSeek R1"]),
    ("ctx_07", "Gemini 3和Llama 4在多模态上打得很激烈", ["Gemini 3", "Llama 4"]),
    ("ctx_08", "Kimi K2的上下文窗口到了一百万token", ["Kimi K2"]),
    ("ctx_09", "Mixtral用的MoE架构所以推理速度快", ["Mixtral", "MoE"]),
    ("ctx_10", "Mistral最近发布了新版本，Grok 4也跟着出了", ["Mistral", "Grok 4"]),
    ("ctx_11", "Kimi和智谱在中文理解上比国外模型好不少", ["Kimi", "智谱"]),
    ("ctx_12", "月之暗面做的是Kimi，智谱做的是GLM", ["月之暗面", "GLM"]),
    ("ctx_13", "豆包和阶跃星辰算是国内第二梯队的代表", ["豆包", "阶跃星辰"]),
    ("ctx_14", "用LangGraph搭multi-agent工作流比直接写省事多了", ["LangGraph", "multi-agent"]),
    ("ctx_15", "Cursor的母公司Anysphere估值已经过百亿了", ["Cursor", "Anysphere"]),
    ("ctx_16", "Windsurf配合Cline来写代码效率提升很大", ["Windsurf", "Cline"]),
    ("ctx_17", "Cognition做的Devin是第一个AI软件工程师", ["Cognition", "Devin"]),
    ("ctx_18", "ElevenLabs的语音合成效果是目前最自然的", ["ElevenLabs"]),
    ("ctx_19", "Dify和Coze都能低代码搭AI应用，但设计理念不一样", ["Dify", "Coze"]),
    ("ctx_20", "用tiktoken算一下会不会超context window的限制", ["tiktoken", "context window"]),
    ("ctx_21", "chain of thought能显著提升LLM的推理表现", ["chain of thought", "LLM"]),
    ("ctx_22", "A2A协议和MCP协议是AI agent互通的两大标准", ["A2A", "MCP"]),
    ("ctx_23", "用LoRA做fine-tuning只需要很少的数据就够了", ["LoRA", "fine-tuning"]),
    ("ctx_24", "现在很多模型用DPO替代RLHF来做对齐训练", ["DPO", "RLHF"]),
    ("ctx_25", "做RAG的话向量数据库推荐用Pinecone或者Qdrant", ["RAG", "Pinecone", "Qdrant"]),
    ("ctx_26", "NVIDIA的Blackwell架构比H100性能强好几倍", ["Blackwell", "H100", "NVIDIA"]),
    ("ctx_27", "FLUX出图质量已经超过Midjourney了", ["FLUX", "Midjourney"]),
    ("ctx_28", "Veo 3的视频生成效果和Sora 2各有千秋", ["Veo 3", "Sora 2"]),
    ("ctx_29", "Hugging Face上开源模型越来越多，用Ollama本地跑很方便", ["Hugging Face", "Ollama"]),
    ("ctx_30", "前端部署到Vercel，后端用Supabase，省事很多", ["Vercel", "Supabase"]),
    ("bare_01", "帮我查一下o3怎么收费的", ["o3"]),
    ("bare_02", "o4-mini和o3-mini有什么区别", ["o4-mini", "o3-mini"]),
    ("bare_03", "今天试了一下vibe coding还挺有意思", ["vibe coding"]),
    ("bare_04", "我朋友推荐了一个叫Lovable的东西", ["Lovable"]),
    ("bare_05", "帮我看看Bolt.new上面那个模板", ["Bolt.new"]),
    ("bare_06", "你知道Anthropic吗就是做Claude的那家", ["Anthropic", "Claude"]),
    ("bare_07", "DeepSeek R1可以本地跑吗", ["DeepSeek R1"]),
    ("bare_08", "Kimi可以免费用吗", ["Kimi"]),
    ("bare_09", "那个Mixtral模型支持中文吗", ["Mixtral"]),
    ("bare_10", "那个叫LangGraph的框架要怎么安装", ["LangGraph"]),
    ("bare_11", "我在Cursor里面装了Cline这个插件", ["Cursor", "Cline"]),
    ("bare_12", "有人用过ElevenLabs吗效果怎么样", ["ElevenLabs"]),
    ("bare_13", "帮我在Dify上面配一个工作流", ["Dify"]),
    ("bare_14", "你听说过A2A协议吗", ["A2A"]),
    ("bare_15", "tiktoken这个库怎么装", ["tiktoken"]),
    ("bare_16", "我想买一张Blackwell架构的显卡", ["Blackwell"]),
    ("bare_17", "FLUX和Midjourney到底哪个好用", ["FLUX", "Midjourney"]),
    ("bare_18", "智谱是哪家公司做的", ["智谱"]),
    ("bare_19", "阶跃星辰最近有什么新模型出来", ["阶跃星辰"]),
    ("bare_20", "Devin好像很贵要五百美金一个月", ["Devin"]),
]


def wav_to_pcm(wav_path):
    with open(wav_path, "rb") as f:
        data = f.read()
    idx = data.find(b"data")
    if idx >= 0 and idx + 8 <= len(data):
        sz = struct.unpack_from("<I", data, idx + 4)[0]
        return data[idx + 8:idx + 8 + sz]
    raise ValueError(f"Bad WAV: {wav_path}")


async def asr_local(pcm, port):
    try:
        async with websockets.connect(f"ws://127.0.0.1:{port}/ws") as ws:
            o = 0
            while o < len(pcm):
                await ws.send(pcm[o:o + CHUNK_SIZE])
                o += CHUNK_SIZE
                await asyncio.sleep(0.03)
            await ws.send(b"")
            txt = ""
            while True:
                m = await asyncio.wait_for(ws.recv(), timeout=30)
                d = json.loads(m)
                if d.get("text"):
                    txt = d["text"]
                if d.get("is_final") or d.get("type") == "completed":
                    break
            return txt.strip()
    except Exception as e:
        return f"[ERROR: {e}]"


def check_target(text, target):
    return target.lower().replace(" ", "") in text.lower().replace(" ", "")


async def main():
    port_no_hw = 18881
    port_hw = 18882

    no_hw_hits = 0
    hw_hits = 0
    total_targets = 0
    diffs = []

    for case_id, ref_text, targets in CASES:
        wav = AUDIO_DIR / f"{case_id}.wav"
        if not wav.exists():
            continue
        pcm = wav_to_pcm(wav)

        r_no_hw, r_hw = await asyncio.gather(
            asr_local(pcm, port_no_hw),
            asr_local(pcm, port_hw),
        )

        for t in targets:
            total_targets += 1
            hit_no = check_target(r_no_hw, t)
            hit_hw = check_target(r_hw, t)
            if hit_no:
                no_hw_hits += 1
            if hit_hw:
                hw_hits += 1
            if hit_no != hit_hw:
                diffs.append({
                    "case": case_id,
                    "target": t,
                    "no_hw": "HIT" if hit_no else "MISS",
                    "hw": "HIT" if hit_hw else "MISS",
                    "no_hw_text": r_no_hw,
                    "hw_text": r_hw,
                })

        # Progress
        print(f"  {case_id}: done", flush=True)

    print("\n" + "=" * 60)
    print(f"总目标词数: {total_targets}")
    print(f"无热词命中: {no_hw_hits}/{total_targets} ({100*no_hw_hits/total_targets:.1f}%)")
    print(f"有热词命中: {hw_hits}/{total_targets} ({100*hw_hits/total_targets:.1f}%)")
    print(f"差异数: {len(diffs)}")
    print("=" * 60)

    if diffs:
        print("\n差异详情:")
        for d in diffs:
            icon = "+" if d["hw"] == "HIT" else "-"
            print(f"\n  [{icon}] {d['case']} / target: {d['target']}")
            print(f"      无热词 ({d['no_hw']}): {d['no_hw_text']}")
            print(f"      有热词 ({d['hw']}):   {d['hw_text']}")


asyncio.run(main())
