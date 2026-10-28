#!/usr/bin/env python3
"""Test Qwen3-ASR-0.6B on the same 10 audio files for comparison."""

import json
import os
import sys
import time

from mlx_qwen3_asr import transcribe

MODEL_PATH = os.path.expanduser("~/.cache/modelscope/hub/models/Qwen/Qwen3-ASR-0.6B")


def score_result(actual, expected, targets):
    results = {}
    for target in targets:
        t = target.lower().replace("-", "").replace(" ", "")
        a = actual.lower().replace("-", "").replace(" ", "")
        results[target] = t in a
    return results


def main():
    audio_dir = sys.argv[1] if len(sys.argv) > 1 else "test-audio"
    sentences_path = os.path.join(audio_dir, "sentences.json")

    with open(sentences_path) as f:
        sentences = json.load(f)

    exts = {".m4a", ".wav", ".mp3", ".aac", ".flac", ".caf"}
    audio_files = sorted(
        (f for f in os.scandir(audio_dir)
        if f.is_file() and os.path.splitext(f.name)[1].lower() in exts),
        key=lambda f: f.name,
    )

    print(f"{'=' * 70}")
    print(f"  Qwen3-ASR-0.6B Test (MLX, Metal GPU)")
    print(f"  Files: {len(audio_files)}  |  Model: {os.path.basename(MODEL_PATH)}")
    print(f"{'=' * 70}")
    print()

    total_targets = 0
    total_hits = 0

    for i, entry in enumerate(audio_files):
        stem = os.path.splitext(entry.name)[0]
        info = sentences.get(stem, {})
        expected = info.get("expected", "(no expected)")
        targets = info.get("targets", [])

        print(f"── [{i+1}/{len(audio_files)}] {entry.name} ──")
        print(f"  Expected: {expected}")

        start = time.monotonic()
        result = transcribe(entry.path, model=MODEL_PATH)
        elapsed = time.monotonic() - start

        text = result.text.strip()
        print(f"  Qwen3:   {text}  ({elapsed:.2f}s)")

        if targets:
            scores = score_result(text, expected, targets)
            hits = sum(1 for v in scores.values() if v)
            total_targets += len(scores)
            total_hits += hits
            marks = "  ".join(f"{'✓' if ok else '✗'} {t}" for t, ok in scores.items())
            print(f"  Score:   {hits}/{len(targets)} — {marks}")
        print()

    print(f"{'=' * 70}")
    print(f"  SUMMARY: {total_hits}/{total_targets} ({total_hits/total_targets*100:.0f}%)" if total_targets else "  No targets")
    print(f"{'=' * 70}")


if __name__ == "__main__":
    main()
