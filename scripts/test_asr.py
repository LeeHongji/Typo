#!/usr/bin/env python3
"""
Type4Me ASR hotword/mapping test harness.

Usage:
    python3 scripts/test_asr.py test-audio/

Reads all .m4a / .wav / .mp3 files from the given directory,
converts to 16kHz mono PCM, sends to Volcengine bigmodel_async,
and prints results alongside expected text (from sentences.json).

Expects:
    - credentials in ~/Library/Application Support/Type4Me/credentials.json
    - ffmpeg on PATH
    - pip install websockets  (already installed)
"""

import asyncio
import gzip
import json
import struct
import subprocess
import sys
import uuid
from pathlib import Path

import websockets

# ── Config ──────────────────────────────────────────────────────────

VOLC_ENDPOINT = "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async"
SENSEVOICE_ENDPOINT = "ws://localhost:{port}/ws"

# Resource IDs — "auto" in credentials.json is resolved client-side, not sent to API
VOLC_RESOURCE_SEED = "volc.seedasr.sauc.duration"
VOLC_RESOURCE_BIG = "volc.bigasr.sauc.duration"
CHUNK_DURATION_MS = 200  # 200ms chunks like the app
SAMPLE_RATE = 16000
BYTES_PER_SAMPLE = 2  # Int16
CHUNK_SIZE = SAMPLE_RATE * BYTES_PER_SAMPLE * CHUNK_DURATION_MS // 1000  # 6400 bytes

CREDENTIALS_PATH = Path.home() / "Library/Application Support/Type4Me/credentials.json"
SENTENCES_FILENAME = "sentences.json"


# ── Volcengine binary protocol ──────────────────────────────────────

def volc_encode_header(msg_type: int, flags: int, serial: int, compress: int) -> bytes:
    """Encode 4-byte Volc header. version=1, headerSize=1."""
    b0 = (0x01 << 4) | 0x01  # version=1, headerSize=1
    b1 = (msg_type << 4) | (flags & 0x0F)
    b2 = (serial << 4) | (compress & 0x0F)
    b3 = 0x00
    return bytes([b0, b1, b2, b3])


def volc_encode_message(msg_type: int, flags: int, serial: int, compress: int, payload: bytes) -> bytes:
    """Encode a full Volc binary message: header + payload_size + payload."""
    header = volc_encode_header(msg_type, flags, serial, compress)
    size = struct.pack(">I", len(payload))
    return header + size + payload


def volc_build_client_request(uid: str, hotwords: list[str] | None = None) -> bytes:
    """Build the full_client_request JSON payload."""
    request_dict = {
        "model_name": "bigmodel",
        "enable_punc": True,
        "enable_ddc": True,
        "enable_nonstream": True,
        "show_utterances": True,
        "result_type": "full",
        "end_window_size": 3000,
        "force_to_speech_time": 1000,
    }

    if hotwords:
        cleaned = [w.strip() for w in hotwords if w.strip()]
        if cleaned:
            ctx = {"hotwords": [{"word": w, "scale": 5.0} for w in cleaned]}
            request_dict["context"] = json.dumps(ctx)

    payload = {
        "user": {"uid": uid},
        "audio": {
            "format": "pcm",
            "codec": "raw",
            "rate": SAMPLE_RATE,
            "bits": 16,
            "channel": 1,
        },
        "request": request_dict,
    }
    return json.dumps(payload).encode("utf-8")


def volc_encode_audio(pcm_data: bytes, is_last: bool) -> bytes:
    """Encode an audio-only request packet."""
    flags = 0b0010 if is_last else 0b0000  # lastPacketNoSequence vs noSequence
    return volc_encode_message(
        msg_type=0b0010,  # audioOnlyRequest
        flags=flags,
        serial=0b0000,    # none
        compress=0b0000,  # none
        payload=pcm_data,
    )


def volc_decode_response(data: bytes) -> dict | None:
    """Decode a Volc server response. Returns parsed JSON or None."""
    if len(data) < 4:
        return None

    b1 = data[1]
    b2 = data[2]
    msg_type = (b1 >> 4) & 0x0F
    flags = b1 & 0x0F
    serial = (b2 >> 4) & 0x0F
    compress = b2 & 0x0F
    header_size = (data[0] & 0x0F) * 4

    offset = header_size

    # Skip sequence number if present
    if flags in (0b0001, 0b0011):  # positiveSequence or negativeSequenceLast
        offset += 4

    if len(data) < offset + 4:
        return None

    payload_size = struct.unpack(">I", data[offset:offset + 4])[0]
    offset += 4

    if len(data) < offset + payload_size:
        return None

    payload = data[offset:offset + payload_size]

    # Server error
    if msg_type == 0x0F:
        if compress == 0b0001 and payload:
            try:
                payload = gzip.decompress(payload)
            except Exception:
                pass
        if serial == 0b0001 and payload:
            try:
                return {"_error": True, **json.loads(payload)}
            except Exception:
                pass
        return {"_error": True, "_raw": payload.hex()[:100]}

    # Decompress
    if compress == 0b0001 and payload:
        payload = gzip.decompress(payload)

    # Parse JSON
    if serial == 0b0001 and payload:
        return json.loads(payload)

    return None


# ── Audio conversion ────────────────────────────────────────────────

def convert_to_pcm(input_path: Path) -> bytes:
    """Convert any audio file to 16kHz mono Int16 PCM using ffmpeg."""
    result = subprocess.run(
        [
            "ffmpeg", "-y", "-i", str(input_path),
            "-ar", str(SAMPLE_RATE),
            "-ac", "1",
            "-f", "s16le",
            "-acodec", "pcm_s16le",
            "pipe:1",
        ],
        capture_output=True,
    )
    if result.returncode != 0:
        raise RuntimeError(f"ffmpeg failed: {result.stderr.decode()[:200]}")
    return result.stdout


# ── Volcengine ASR ──────────────────────────────────────────────────

async def recognize_volc(
    pcm_data: bytes,
    app_key: str,
    access_key: str,
    resource_id: str,
    hotwords: list[str] | None = None,
) -> str:
    """Send PCM audio to Volcengine and return the final transcript."""
    uid = f"test-{uuid.uuid4().hex[:8]}"
    connect_id = str(uuid.uuid4())

    headers = {
        "X-Api-App-Key": app_key,
        "X-Api-Access-Key": access_key,
        "X-Api-Resource-Id": resource_id,
        "X-Api-Connect-Id": connect_id,
    }

    async with websockets.connect(VOLC_ENDPOINT, additional_headers=headers) as ws:
        # 1. Send full_client_request
        req_payload = volc_build_client_request(uid, hotwords=hotwords)
        req_msg = volc_encode_message(
            msg_type=0b0001,  # fullClientRequest
            flags=0b0000,     # noSequence
            serial=0b0001,    # json
            compress=0b0000,  # none
            payload=req_payload,
        )
        await ws.send(req_msg)

        # 2. Send audio in chunks
        offset = 0
        while offset < len(pcm_data):
            chunk = pcm_data[offset:offset + CHUNK_SIZE]
            is_last = (offset + CHUNK_SIZE >= len(pcm_data))
            pkt = volc_encode_audio(chunk, is_last=is_last)
            await ws.send(pkt)
            offset += CHUNK_SIZE
            if not is_last:
                await asyncio.sleep(CHUNK_DURATION_MS / 1000 * 0.5)  # pace it

        # 3. Receive until done
        final_text = ""
        try:
            while True:
                msg = await asyncio.wait_for(ws.recv(), timeout=15)
                if isinstance(msg, bytes):
                    parsed = volc_decode_response(msg)
                    if parsed is None:
                        continue
                    if parsed.get("_error"):
                        # bigmodel_async sends 0xF0 as "done" signal
                        break

                    result = parsed.get("result", parsed)
                    text = result.get("text", "")
                    if text:
                        final_text = text

                    # Check utterances for definite segments
                    utts = result.get("utterances", [])
                    definite_texts = [u["text"] for u in utts if u.get("definite")]
                    if definite_texts:
                        final_text = "".join(definite_texts)
        except asyncio.TimeoutError:
            pass
        except websockets.exceptions.ConnectionClosed:
            pass

    return final_text.strip()


# ── SenseVoice ASR ──────────────────────────────────────────────────

async def recognize_sensevoice(pcm_data: bytes, port: int = 10095) -> str:
    """Send PCM audio to local SenseVoice server and return the final transcript."""
    url = SENSEVOICE_ENDPOINT.format(port=port)

    try:
        async with websockets.connect(url) as ws:
            # Send audio in chunks
            offset = 0
            while offset < len(pcm_data):
                chunk = pcm_data[offset:offset + CHUNK_SIZE]
                await ws.send(chunk)
                offset += CHUNK_SIZE
                await asyncio.sleep(CHUNK_DURATION_MS / 1000 * 0.3)

            # Send empty frame = end of audio
            await ws.send(b"")

            # Receive final result
            final_text = ""
            try:
                while True:
                    msg = await asyncio.wait_for(ws.recv(), timeout=30)
                    data = json.loads(msg)
                    text = data.get("text", "")
                    if text:
                        final_text = text
                    if data.get("is_final"):
                        break
            except asyncio.TimeoutError:
                pass
            except websockets.exceptions.ConnectionClosed:
                pass

            return final_text.strip()
    except (ConnectionRefusedError, OSError):
        return "[SenseVoice server not running]"


# ── Main ────────────────────────────────────────────────────────────

def load_credentials() -> dict:
    if not CREDENTIALS_PATH.exists():
        sys.exit(f"Credentials not found: {CREDENTIALS_PATH}")
    with open(CREDENTIALS_PATH) as f:
        return json.load(f)


def load_sentences(audio_dir: Path) -> dict[str, dict]:
    """Load sentences.json mapping: filename -> {expected, targets}."""
    path = audio_dir / SENTENCES_FILENAME
    if not path.exists():
        return {}
    with open(path) as f:
        return json.load(f)


def find_audio_files(audio_dir: Path) -> list[Path]:
    exts = {".m4a", ".wav", ".mp3", ".aac", ".ogg", ".flac", ".caf"}
    files = sorted(f for f in audio_dir.iterdir() if f.suffix.lower() in exts)
    return files


def score_result(actual: str, expected: str, targets: list[str]) -> dict:
    """Check which target words appear correctly in actual output."""
    results = {}
    for target in targets:
        target_lower = target.lower().replace("-", "").replace(" ", "")
        actual_check = actual.lower().replace("-", "").replace(" ", "")
        results[target] = target_lower in actual_check
    return results


async def main():
    if len(sys.argv) < 2:
        print("Usage: python3 scripts/test_asr.py <audio-dir> [--sensevoice] [--hotwords word1,word2,...]")
        print()
        print("Options:")
        print("  --sensevoice          Also test with local SenseVoice server")
        print("  --hotwords w1,w2,...   Add hotwords for Volcengine boosting")
        print()
        print("Audio dir should contain:")
        print("  - Audio files (.m4a, .wav, etc.)")
        print("  - sentences.json with expected text per file")
        sys.exit(1)

    audio_dir = Path(sys.argv[1])
    if not audio_dir.is_dir():
        sys.exit(f"Not a directory: {audio_dir}")

    test_sensevoice = "--sensevoice" in sys.argv
    hotwords = None
    for arg in sys.argv:
        if arg.startswith("--hotwords="):
            hotwords = arg.split("=", 1)[1].split(",")
        elif arg == "--hotwords":
            idx = sys.argv.index(arg)
            if idx + 1 < len(sys.argv):
                hotwords = sys.argv[idx + 1].split(",")

    # Load credentials
    creds = load_credentials()
    volc = creds.get("tf_asr_volcano", {})
    app_key = volc.get("appKey", "")
    access_key = volc.get("accessKey", "")
    resource_id = volc.get("resourceId", "auto")
    # Resolve "auto" the same way the Swift app does
    if not resource_id or resource_id == "auto":
        resource_id = VOLC_RESOURCE_SEED

    if not app_key or not access_key:
        sys.exit("Volcengine credentials missing in credentials.json")

    # Load expected sentences
    sentences = load_sentences(audio_dir)

    # Find audio files
    audio_files = find_audio_files(audio_dir)
    if not audio_files:
        sys.exit(f"No audio files found in {audio_dir}")

    print(f"{'=' * 70}")
    print(f"  Type4Me ASR Test Harness")
    print(f"  Files: {len(audio_files)}  |  Hotwords: {len(hotwords) if hotwords else 0}")
    print(f"  Engines: Volcengine" + (" + SenseVoice" if test_sensevoice else ""))
    print(f"{'=' * 70}")
    print()

    all_results = []

    for i, audio_file in enumerate(audio_files):
        stem = audio_file.stem
        info = sentences.get(stem, sentences.get(audio_file.name, {}))
        expected = info.get("expected", "(no expected text)")
        targets = info.get("targets", [])

        print(f"── [{i+1}/{len(audio_files)}] {audio_file.name} ──")
        print(f"  Expected: {expected}")
        if targets:
            print(f"  Targets:  {', '.join(targets)}")

        # Convert audio
        try:
            pcm = convert_to_pcm(audio_file)
            duration_s = len(pcm) / (SAMPLE_RATE * BYTES_PER_SAMPLE)
            print(f"  Duration: {duration_s:.1f}s ({len(pcm)} bytes PCM)")
        except RuntimeError as e:
            print(f"  ERROR converting: {e}")
            print()
            continue

        # Volcengine
        try:
            volc_text = await recognize_volc(pcm, app_key, access_key, resource_id, hotwords=hotwords)
            print(f"  Volc:     {volc_text}")
            if targets:
                scores = score_result(volc_text, expected, targets)
                hits = sum(1 for v in scores.values() if v)
                marks = "  ".join(
                    f"{'✓' if ok else '✗'} {t}" for t, ok in scores.items()
                )
                print(f"  Score:    {hits}/{len(targets)} — {marks}")
        except Exception as e:
            volc_text = f"[ERROR: {e}]"
            print(f"  Volc:     {volc_text}")
            scores = {}

        # SenseVoice (optional)
        sv_text = None
        if test_sensevoice:
            sv_text = await recognize_sensevoice(pcm)
            print(f"  SV:       {sv_text}")
            if targets and sv_text and not sv_text.startswith("["):
                sv_scores = score_result(sv_text, expected, targets)
                sv_hits = sum(1 for v in sv_scores.values() if v)
                sv_marks = "  ".join(
                    f"{'✓' if ok else '✗'} {t}" for t, ok in sv_scores.items()
                )
                print(f"  SV Score: {sv_hits}/{len(targets)} — {sv_marks}")

        result = {
            "file": audio_file.name,
            "expected": expected,
            "targets": targets,
            "volc_text": volc_text,
        }
        if sv_text:
            result["sv_text"] = sv_text
        all_results.append(result)
        print()

    # Summary
    print(f"{'=' * 70}")
    print("  SUMMARY")
    print(f"{'=' * 70}")

    total_targets = 0
    total_hits = 0
    for r in all_results:
        if r["targets"] and not r["volc_text"].startswith("["):
            scores = score_result(r["volc_text"], r["expected"], r["targets"])
            total_targets += len(scores)
            total_hits += sum(1 for v in scores.values() if v)

    if total_targets > 0:
        pct = total_hits / total_targets * 100
        print(f"  Volcengine target word accuracy: {total_hits}/{total_targets} ({pct:.0f}%)")
    else:
        print("  No target words to score.")

    # Save detailed results
    output_path = audio_dir / "results.json"
    with open(output_path, "w") as f:
        json.dump(all_results, f, ensure_ascii=False, indent=2)
    print(f"  Detailed results saved to: {output_path}")
    print()


if __name__ == "__main__":
    asyncio.run(main())
