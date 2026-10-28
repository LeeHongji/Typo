# Native SenseVoice Implementation Plan

> **归档文档 · 已实施的历史计划（2026-04-01）**：任务清单不再作为当前待办。当前文档入口见 `docs/README.md`。

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace Python SenseVoice service with native Swift (sherpa-onnx), bundle Qwen3-ASR 8-bit model, reduce app from ~3.3GB to ~1.47GB.

**Architecture:** SenseVoice recognition moves from Python WebSocket service to in-process sherpa-onnx C API calls. Qwen3-ASR stays as Python MLX service but switches to 8-bit quantized model. The `SenseVoiceASRClient.swift` (deleted in 4ebd717) is restored as the primary local ASR client.

**Tech Stack:** Swift 6, sherpa-onnx C API (v1.12.33), ONNX Runtime, Silero VAD, MLX (Qwen3)

**Design Doc:** `docs/archive/plans/2026-04-01-native-sensevoice-design.md`

---

### Task 1: Build sherpa-onnx.xcframework

Ensure the xcframework is built and available. This is a prerequisite for all subsequent tasks.

**Files:**
- Run: `scripts/build-sherpa.sh`
- Verify: `Frameworks/sherpa-onnx.xcframework/Info.plist` exists

**Step 1: Build xcframework**

```bash
cd ~/projects/type4me
bash scripts/build-sherpa.sh
```

Expected: xcframework at `Frameworks/sherpa-onnx.xcframework/`

**Step 2: Verify build**

```bash
ls -la Frameworks/sherpa-onnx.xcframework/Info.plist
swift build -c debug 2>&1 | tail -5
```

Expected: file exists, build succeeds

**Step 3: Commit if new build**

```bash
# xcframework is gitignored, no commit needed
```

---

### Task 2: Make sherpa-onnx required in Package.swift

Remove the conditional `HAS_SHERPA_ONNX` flag. sherpa-onnx is now a required dependency.

**Files:**
- Modify: `Package.swift`

**Step 1: Update Package.swift**

Remove the `hasSherpaFramework` conditional check. Make the `SherpaOnnxLib` binary target and `HAS_SHERPA_ONNX` define always active.

Key changes:
- Remove `let hasSherpaFramework = FileManager.default.fileExists(...)` check
- Always include the binary target for `SherpaOnnxLib`
- Always define `HAS_SHERPA_ONNX` in swiftSettings
- Always add `SherpaOnnxLib` to target dependencies

**Step 2: Verify build**

```bash
swift build -c debug 2>&1 | tail -5
```

Expected: Build succeeds with sherpa-onnx always linked

**Step 3: Commit**

```bash
git add Package.swift
git commit -m "build: make sherpa-onnx a required dependency"
```

---

### Task 3: Restore SenseVoiceASRClient.swift

Recover the deleted sherpa-onnx-based SenseVoice client from git history.

**Files:**
- Restore: `Type4Me/ASR/SenseVoiceASRClient.swift` (from `git show 4ebd717^:Type4Me/ASR/SenseVoiceASRClient.swift`)

**Step 1: Restore file**

```bash
cd ~/projects/type4me
git show 4ebd717^:Type4Me/ASR/SenseVoiceASRClient.swift > Type4Me/ASR/SenseVoiceASRClient.swift
```

**Step 2: Remove `#if HAS_SHERPA_ONNX` guards**

The file is wrapped in `#if HAS_SHERPA_ONNX ... #endif`. Since sherpa-onnx is now required, remove these guards but keep the `import SherpaOnnxLib`.

**Step 3: Update model paths**

Change `SherpaASRConfig` to look for models in:
1. App bundle `Contents/Resources/Models/` (for bundled models)
2. `~/Library/Application Support/Type4Me/models/` (for downloaded models, existing behavior)

The int8 ONNX model is at: `sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17/`
The Silero VAD model is at: `silero_vad/silero_vad.onnx`

**Step 4: Verify build**

```bash
swift build -c debug 2>&1 | tail -5
```

Expected: Build succeeds

**Step 5: Commit**

```bash
git add Type4Me/ASR/SenseVoiceASRClient.swift
git commit -m "feat: restore native SenseVoice client (sherpa-onnx)"
```

---

### Task 4: Update ASRProviderRegistry

Wire up the restored `SenseVoiceASRClient` as the client for the `.sherpa` provider.

**Files:**
- Modify: `Type4Me/ASR/ASRProviderRegistry.swift`

**Step 1: Update sherpa provider entry**

Change:
```swift
#if canImport(SherpaOnnxLib)
dict[.sherpa] = ProviderEntry(
    configType: SherpaASRConfig.self,
    createClient: { SenseVoiceWSClient() },  // OLD: WebSocket to Python
    capabilities: .batch()
)
#else
dict[.sherpa] = ProviderEntry(configType: SherpaASRConfig.self, createClient: nil)
#endif
```

To:
```swift
dict[.sherpa] = ProviderEntry(
    configType: SherpaASRConfig.self,
    createClient: { SenseVoiceASRClient() },  // NEW: native sherpa-onnx
    capabilities: .batch()
)
```

Remove the `#if canImport` conditional since sherpa-onnx is now required.

**Step 2: Verify build**

```bash
swift build -c debug 2>&1 | tail -5
```

**Step 3: Commit**

```bash
git add Type4Me/ASR/ASRProviderRegistry.swift
git commit -m "feat: wire SenseVoiceASRClient as local ASR provider"
```

---

### Task 5: Update SenseVoiceServerManager

Remove SenseVoice Python server management. Keep only Qwen3-ASR server management.

**Files:**
- Modify: `Type4Me/Services/SenseVoiceServerManager.swift`

**Step 1: Remove SenseVoice server lifecycle**

Key changes:
- Remove `process` (SenseVoice Python process) property and all launch/stop logic for it
- Remove `port` property for SenseVoice (keep `qwen3Port`)
- Remove `wsURL` (SenseVoice WebSocket URL)
- Remove `healthURL` (SenseVoice health check)
- Keep `qwen3WSURL`, `qwen3Process`, `qwen3Port`, `launchQwen3Server()`
- Update `start()` to only launch Qwen3
- Update `stop()` to only stop Qwen3
- Remove `syncHotwordsFile()` (hotwords file was for SenseVoice Python)
- Remove `syncHotwordsAndRestart()` (only restarted SenseVoice)
- Consider renaming class to `Qwen3ServerManager` or keep name for minimal diff

**Step 2: Update references**

Search for any code that references `SenseVoiceServerManager.shared.port` or `.wsURL` and update/remove.

**Step 3: Verify build**

```bash
swift build -c debug 2>&1 | tail -5
```

**Step 4: Commit**

```bash
git add Type4Me/Services/SenseVoiceServerManager.swift
git commit -m "refactor: remove SenseVoice Python from ServerManager, keep Qwen3 only"
```

---

### Task 6: Update SenseVoiceWSClient

This client currently handles three modes: SenseVoice streaming, Qwen3-only, and hybrid. Remove SenseVoice streaming mode since that's now handled by `SenseVoiceASRClient`. Keep Qwen3 WebSocket functionality.

**Files:**
- Modify: `Type4Me/ASR/SenseVoiceWSClient.swift`

**Step 1: Simplify to Qwen3-only client**

Key changes:
- Remove SenseVoice WebSocket connection logic (the `ws://127.0.0.1:{svPort}/ws` connection)
- Remove SenseVoice streaming partial handling
- Keep Qwen3 WebSocket connection (`ws://127.0.0.1:{q3Port}/ws`)
- Keep Qwen3 speculative transcription logic
- The client is now only used when Qwen3 final calibration is needed
- Consider renaming to `Qwen3ASRClient` or keep name for minimal diff

**Step 2: Update connect() logic**

Remove the three-mode branching (SenseVoice-only, Qwen3-only, hybrid). Now this client only does Qwen3 final calibration. It receives complete audio and sends to Qwen3 for transcription.

**Step 3: Verify build**

```bash
swift build -c debug 2>&1 | tail -5
```

**Step 4: Commit**

```bash
git add Type4Me/ASR/SenseVoiceWSClient.swift
git commit -m "refactor: simplify WSClient to Qwen3-only mode"
```

---

### Task 7: Update package-app.sh for new bundling

Update the packaging script to bundle sherpa-onnx models and Qwen3-ASR 8-bit instead of the Python SenseVoice server.

**Files:**
- Modify: `scripts/package-app.sh`

**Step 1: Update model bundling**

Key changes:
- Remove `BUNDLE_SENSEVOICE_MODEL` flag and SenseVoice model copy from modelscope cache
- Always bundle sherpa-onnx SenseVoice models (int8 ONNX + tokens.txt) from `~/Library/Application Support/Type4Me/models/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17/`
- Always bundle Silero VAD model from `~/Library/Application Support/Type4Me/models/silero_vad/`
- Remove `BUNDLE_LOCAL_ASR` flag and sensevoice-server-dist copy logic
- Update Qwen3 model source to `mlx-community/Qwen3-ASR-0.6B-8bit` (download if not cached)
- Keep qwen3-asr-server bundling (still Python)
- Remove sensevoice-server signing/temp move logic from codesign section

**Step 2: Update SherpaASRConfig model paths**

Ensure `SherpaASRConfig` checks app bundle path first:
```swift
let bundlePath = Bundle.main.resourcePath! + "/Models/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17"
let appSupportPath = "~/Library/Application Support/Type4Me/models/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17"
```

**Step 3: Verify packaging**

```bash
APP_PATH=/tmp/Type4Me-test.app bash scripts/package-app.sh
ls -la /tmp/Type4Me-test.app/Contents/Resources/Models/
```

Expected: SenseVoice int8 model and Silero VAD in Models/

**Step 4: Commit**

```bash
git add scripts/package-app.sh Type4Me/ASR/Providers/SherpaASRConfig.swift
git commit -m "build: bundle sherpa-onnx models, remove Python SenseVoice packaging"
```

---

### Task 8: Download Qwen3-ASR-0.6B 8-bit model

Download the MLX-community quantized model for bundling.

**Step 1: Download model**

```bash
pip install huggingface_hub
huggingface-cli download mlx-community/Qwen3-ASR-0.6B-8bit --local-dir ~/Library/Application\ Support/Type4Me/models/Qwen3-ASR-0.6B-8bit
```

**Step 2: Update qwen3-asr-server to use 8-bit model**

Update `SenseVoiceServerManager` (or wherever Qwen3 model path is configured) to point to the 8-bit model path.

**Step 3: Verify Qwen3 8-bit works**

```bash
cd ~/projects/type4me/qwen3-asr-server
source .venv/bin/activate
python server.py --model-path ~/Library/Application\ Support/Type4Me/models/Qwen3-ASR-0.6B-8bit --port 19999
# In another terminal, test with a WAV file
```

**Step 4: Commit**

```bash
git commit -m "feat: switch Qwen3-ASR to 8-bit quantized model"
```

---

### Task 9: Clean up sensevoice-server references

Remove or archive the Python SenseVoice server since it's no longer used.

**Files:**
- Delete or gitignore: `sensevoice-server/` directory (keep for reference or delete)
- Modify: any remaining references to sensevoice-server in codebase

**Step 1: Search for remaining references**

```bash
grep -r "sensevoice-server\|sensevoice_server\|BUNDLE_LOCAL_ASR\|BUNDLE_SENSEVOICE" --include="*.swift" --include="*.sh" --include="*.md" . | grep -v docs/archive/plans | grep -v .build
```

**Step 2: Clean up references**

Remove any remaining references to the Python SenseVoice server, `BUNDLE_LOCAL_ASR` flag, `BUNDLE_SENSEVOICE_MODEL` flag.

**Step 3: Commit**

```bash
git commit -m "chore: remove Python SenseVoice server references"
```

---

### Task 10: Integration test

Full end-to-end verification.

**Step 1: Build and deploy**

```bash
cd ~/projects/type4me
swift build -c release
BUNDLE_LOCAL_ASR=1 bash scripts/deploy.sh
```

**Step 2: Manual test checklist**

- [ ] App launches without Python SenseVoice server
- [ ] Local ASR (sherpa provider) works: press hotkey, speak, get text
- [ ] Partial results appear during speech (VAD + offline decode)
- [ ] Final result is correct after releasing key
- [ ] Qwen3-ASR calibration works (if enabled in settings)
- [ ] Cloud ASR providers still work (Volcengine, etc.)
- [ ] Hotword settings UI still present (for cloud providers)
- [ ] No Python SenseVoice process in Activity Monitor

**Step 3: Check app bundle size**

```bash
du -sh /Applications/Type4Me.app
```

Expected: ~1.4-1.5GB (down from ~3.3GB)

**Step 4: Final commit**

```bash
git commit -m "test: verify native SenseVoice integration"
```
