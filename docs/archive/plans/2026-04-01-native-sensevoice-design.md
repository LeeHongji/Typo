# SenseVoice Native Swift + Qwen3-ASR 8-bit Design

> **归档文档 · 已实施的历史设计（2026-04-01）**：用于追溯本地 ASR 架构演进，不代表当前完整实现说明。当前文档入口见 `docs/README.md`。

**Date**: 2026-04-01
**Status**: Approved
**Goal**: Replace Python SenseVoice service with native Swift (sherpa-onnx), bundle Qwen3-ASR 8-bit model. Reduce app from ~3.3GB to ~1.47GB.

## Background

Type4Me's local ASR currently runs two Python services:
- **SenseVoice** (767MB PyInstaller + 229MB model): streaming partial + final recognition
- **Qwen3-ASR** (230MB PyInstaller + ~1.5GB model): optional final calibration on Apple Silicon

The SenseVoice Python service is bloated because PyInstaller bundles PyTorch (288MB), llvmlite (110MB), and funasr's unused dependencies (matplotlib, PIL, jieba, sklearn = 151MB). The actual runtime only needs ONNX Runtime + FBANK + CTC decode.

sherpa-onnx already has SenseVoice offline support via C API, and the project previously had a working Swift implementation (`SenseVoiceASRClient.swift`, deleted in commit 4ebd717) using VAD + periodic offline recognition.

### Key decisions

- **Hotword support removed for local SenseVoice**: sherpa-onnx only supports greedy search for SenseVoice. Testing showed hotwords only improved 6/83 target words (+7.2%). Cloud providers (Volcengine, Deepgram) and Qwen3-ASR retain hotword support.
- **Pseudo-streaming acceptable**: sherpa-onnx SenseVoice is offline-only. Partial results are simulated via VAD + periodic offline decode (~200ms intervals). Previous implementation validated this approach.
- **Qwen3-ASR stays on Python MLX**: MLX's 230MB runtime is irreducible (125MB metallib). Model switches to `mlx-community/Qwen3-ASR-0.6B-8bit` (960MB, WER +0.04pp, 3.1x faster).

## Architecture

### Before

```
Recording -> Swift -> WebSocket -> Python SenseVoice (767MB) -> WebSocket -> Swift
                                   Python Qwen3-ASR (230MB)
```

### After

```
Recording -> Swift -> sherpa-onnx C API (in-process, zero overhead)
                   -> Python Qwen3-ASR (230MB, retained)
```

## Recognition Flow

```
User presses key -> recording starts
  |
  v
PCM audio chunks (200ms, 6400 bytes)
  |
  v
SenseVoiceASRClient (Swift, in-process):
  -> Skip first 6400 samples (400ms, avoid start-sound bleed)
  -> Silero VAD (512 samples/window)
  -> During speech: every 3200 samples (~200ms), run offline recognizer -> partial
  -> VAD detects silence: finalized segment -> confirmed
  |
  v
User releases key -> endAudio()
  -> Flush VAD -> final offline recognition
  -> (optional) Send full audio to Qwen3-ASR for calibration
  -> Output final text
```

## File Changes

| File | Action | Details |
|------|--------|---------|
| `Type4Me/ASR/SenseVoiceASRClient.swift` | **Restore** from git `4ebd717^` | sherpa-onnx offline + Silero VAD |
| `Type4Me/ASR/SenseVoiceWSClient.swift` | **Modify** | Remove SenseVoice streaming mode, keep Qwen3 WebSocket connection |
| `Type4Me/Services/SenseVoiceServerManager.swift` | **Modify** | Remove SenseVoice Python lifecycle, keep Qwen3 only |
| `Type4Me/ASR/ASRProviderRegistry.swift` | **Update** | sherpa provider as default local ASR |
| `Type4Me/ASR/Providers/SherpaASRConfig.swift` | **Update** | Model paths point to app bundle |
| `Package.swift` | **Update** | sherpa-onnx.xcframework becomes required (remove conditional) |
| `scripts/deploy.sh` | **Update** | Bundle SenseVoice + Silero VAD + Qwen3-ASR models |
| `scripts/build-dmg.sh` | **Update** | Single DMG variant (no more lite vs full split) |
| `sensevoice-server/` | **Delete** | No longer needed |
| Qwen3 model | **Replace** | `Qwen/Qwen3-ASR-0.6B` -> `mlx-community/Qwen3-ASR-0.6B-8bit` |

## Bundled Resources

| Resource | Size | Location |
|----------|------|----------|
| sherpa-onnx.xcframework | ~25MB | `Frameworks/` (static linked) |
| SenseVoice int8 ONNX model | 229MB | App bundle `Resources/models/` |
| Silero VAD model | 0.6MB | App bundle `Resources/models/` |
| tokens.txt | ~2MB | App bundle `Resources/models/` |
| Qwen3-ASR-0.6B 8-bit (MLX) | 960MB | App bundle `Resources/models/` |
| Qwen3 Python runtime (PyInstaller) | 230MB | App bundle |
| **Total** | **~1.47GB** | |

## Unchanged

- All cloud ASR providers (Volcengine, Deepgram, OpenAI, AssemblyAI, Soniox, Bailian, Baidu)
- Hotword settings UI (hotwords still used by cloud providers + Qwen3-ASR)
- LLM post-processing
- SpeechRecognizer protocol
- RecognitionSession state machine
- Audio capture (AVAudioEngine)
- Text injection (clipboard paste)
- All UI

## Risks

1. **Partial quality regression**: Pseudo-streaming (VAD + offline) may feel less responsive than true streaming. Mitigated by 200ms recognition interval.
2. **No hotword boosting for local ASR**: Accepted. Cloud providers and Qwen3 still support hotwords.
3. **sherpa-onnx build**: xcframework build requires cmake + toolchain. Already working via `build-sherpa.sh`.
