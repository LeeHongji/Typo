# Type4Me — Development Guide

## Overview

macOS menu bar voice input tool with dual-engine local ASR, multi-provider cloud ASR, and LLM post-processing.
Local ASR: SenseVoice via native sherpa-onnx (streaming) + Qwen3-ASR (final calibration, Python WebSocket service managed by `SenseVoiceServerManager`).
Cloud ASR: 18 providers implemented (Volcano, StepFun, MiMo batch, OpenAI, Microsoft Azure MAI, Deepgram, Cartesia, AssemblyAI, ElevenLabs, Gemini, Grok, Soniox, Bailian, Baidu, Meta Muse, Groq batch, Mistral AI batch, Tencent Cloud), plus Apple Speech. StepFun, Bailian, Gemini, ElevenLabs, Grok, Microsoft Azure, and Tencent Cloud let users switch between real-time streaming and batch recognition.
Swift Package Manager project, no Xcode project file. Optional `sherpa-onnx.xcframework` enables local SenseVoice, Silero VAD, and punctuation restoration.

### This repository

This checkout is a fork. `origin` is `https://github.com/LeeHongji/Typo` (public); the upstream project is `joewongjc/type4me`. The fork adds the Typo keycap companion, the locked dictation target with quotes and screenshots, and network-loss recovery on top of the upstream baseline `99c66e9`. The app, bundle identifier, and user-facing name remain Type4Me; "Typo" names the mascot and the repository only. README download links and badges still point at upstream releases because this fork publishes none.

Documentation lives under `docs/`; `docs/README.md` is the index and states which documents are current. Code wins when a document disagrees with it.

## Branch Naming and Lifecycle

Use one short-lived branch for one independently reviewable change. Branches must
use lowercase ASCII kebab-case and follow this form:

```
<type>/<issue-number-optional>-<concise-description>
```

Examples:

```
feat/241-cartesia-streaming-asr
fix/247-agent-context-cleanup
docs/intelli-sense-pangu-terminology
perf/reduce-startup-latency
refactor/session-output-pipeline
test/recognition-session-recovery
chore/update-swift-format
release/2.1.1
hotfix/251-crash-on-launch
```

### Allowed types

| Type | Use for |
| --- | --- |
| `feat` | A user-visible capability or substantial new behavior. |
| `fix` | A defect fix. Prefix the issue number when one exists. |
| `docs` | Documentation-only changes. |
| `perf` | A measurable performance improvement without a primary behavior change. |
| `refactor` | Internal restructuring with no intended behavior change. |
| `test` | Test-only additions or repairs. |
| `chore` | Tooling, repository maintenance, or non-product housekeeping. |
| `release` | Release preparation and versioning. |
| `hotfix` | An urgent production fix. |

### Rules

- Do not use agent, tool, model, or personal prefixes such as `agent/`,
  `codex/`, `builder/`, or a username. These are execution details, not work
  categories.
- Do not create a branch named only after a PR number, and do not combine
  unrelated changes on one branch.
- Keep descriptions specific but compact: prefer `fix/247-agent-context-cleanup`
  over `fix/247-fix-the-problem-reported-in-the-agent-context-issue`.
- Use the same branch name locally and on its published review branch.
  `origin/main` is updated only with explicit user authorization.
- Before merging or opening a PR, rebase or otherwise bring the branch up to
  date with the current `origin/main` as appropriate for the requested
  workflow. Use `--force-with-lease`, never a blind force push, after a
  published branch is rebased.
- After the change is confirmed in `main`, delete its local and published
  remote branches unless there is an explicitly stated reason to retain them.
  Never delete an integration branch without explicit authorization.
- `main` is the integration branch. Work directly on it, or push directly to
  `origin/main`, only when the user explicitly asks for a direct change.

Existing long-lived feature branches are exceptions until they are merged or
explicitly retired; do not rename them merely to satisfy this convention.

## Build & Run

```bash
# Qwen3-ASR server setup (optional, Apple Silicon only)
cd Sources/qwen3-asr-server && python3.12 -m venv .venv && source .venv/bin/activate && pip install -r requirements.txt && cd ../..

# Optional: local SenseVoice, Silero VAD, and punctuation module (~5 min, requires cmake)
bash scripts/build-sherpa.sh

swift build -c release
```

The built binary is at `.build/release/Type4Me`.

- “本地部署”“装一下”“给我体验”等请求默认授权按正式应用流程打包，备份后替换 `/Applications/Type4Me.app`。保留 `com.type4me.app`、登录钥匙串中的 Developer ID Application 签名（Team `T98LK79X2K`）及 designated requirement，完成构建、签名与安装完整性检查后交给用户体验。仅在用户明确要求 Dev 版时使用独立 Dev app。
- 公证只用登录钥匙串里的 notarytool profile `selectx-notary`（Team `T98LK79X2K` 共用，`scripts/setup-notary-profile.sh` 写入、`scripts/build-dmg.sh` 读取）。代理不得创建、覆盖、改名或删除任何公证 profile；凭据失效时停下，请用户自己运行 setup 脚本。
- 本地 UI 迭代的测试和实际体验默认交给用户。除非用户明确要求，不自行运行测试套件、操作界面测试、切换设置或启动录音；仅完成必要的编译、签名、备份和安装完整性检查。用户提供的截图和体验反馈是下一轮调整依据。
- Use `$type4me-deploy` and the current production packaging flow; default to `pure` + universal. Explicit Dev-only requests use `scripts/dev-run.sh`.
- Local deployment does not authorize GitHub publication or the archived `official` subscription variant.

## Build Variants

Two supported product variants are built from the same codebase via conditional compilation flags. The compact CppJieba experiment is an independent optional capability:

| Variant | `HAS_SHERPA_ONNX` | `HAS_CLOUD_SUBSCRIPTION` | Arch | Description |
|---------|---|---|---|---|
| **pure** | no | no | universal | Open-source cloud edition (BYOK API keys) |
| **official** | no | yes | universal | Archived subscription edition; the build script intentionally rejects it. |
| **local** | yes | no | arm64 | Open-source local edition (bundled SenseVoice + Qwen3-ASR) |

`ENABLE_CPPJIEBA=1` keeps `Sources/CppJiebaBridge/marker` visible while running `build-dmg.sh`, which adds the C++ bridge and compact dictionary resources. It defaults to `0`, so normal release packages do not pay the binary/resource cost until the experiment is explicitly enabled. A compiled build also has the local `tf_cppJiebaExperimentEnabled` runtime switch; disabling it falls back to `NLTokenizer` without rebuilding.

### Subscription paused (2026-04)

We are not developing the subscription feature for the foreseeable future. The
`Sources/Type4Me/CloudSubscription/marker` file has been renamed to
`marker.archived-no-subscription`, so `swift build`, `deploy.sh`, and
`build-dmg.sh VARIANT=pure|local` all default to the no-subscription path.
`build-dmg.sh VARIANT=official` now fails fast with re-enable instructions.

The `Sources/Type4Me/CloudSubscription/` source directory is preserved as-is for
future reactivation. To re-enable:

```bash
mv Sources/Type4Me/CloudSubscription/marker.archived-no-subscription \
   Sources/Type4Me/CloudSubscription/marker
swift package clean
```

Public GitHub Releases ship only `pure` (universal) and `local` (arm64).

### How it works

- `HAS_SHERPA_ONNX`: controlled by `Frameworks/sherpa-onnx.xcframework/Info.plist` presence (existing pattern)
- `HAS_CLOUD_SUBSCRIPTION`: controlled by `Sources/Type4Me/CloudSubscription/marker` file presence
- `Package.swift` detects these files at manifest evaluation time and sets compiler defines + source excludes
- `build-dmg.sh` temporarily hides marker files to build each variant

### Build commands

```bash
# Open-source cloud edition (no subscription, no local ASR)
VARIANT=pure bash scripts/build-dmg.sh

# Same edition with the compact CppJieba experiment enabled
ENABLE_CPPJIEBA=1 VARIANT=pure bash scripts/build-dmg.sh

# Open-source local edition (bundled models, Apple Silicon only)
VARIANT=local bash scripts/build-dmg.sh

# Official member edition — archived, see "Subscription paused" above.
# VARIANT=official bash scripts/build-dmg.sh
```

### Subscription code location

All subscription/cloud-proxy code lives in `Sources/Type4Me/CloudSubscription/`. Main code uses `#if HAS_CLOUD_SUBSCRIPTION` guards; when the marker is absent, the directory is excluded from compilation entirely.

**Important**: SPM caches manifest evaluation in `~/Library/Caches/org.swift.swiftpm`. When switching variants manually (not via build-dmg.sh), clear this cache: `rm -rf .build ~/Library/Caches/org.swift.swiftpm`

## ASR Provider Architecture

Multi-provider ASR support via `ASRProvider` enum + `ASRProviderConfig` protocol + `ASRProviderRegistry`.

- `ASRProvider` enum: 25 standard cases (`sherpa`, `apple`, international and China cloud providers, and `custom`), plus conditional `cloud` when `HAS_CLOUD_SUBSCRIPTION` is enabled.
- Each provider has its own Config type (e.g., `SherpaASRConfig`, `VolcanoASRConfig`, `MetaMuseASRConfig`) defining `credentialFields` for dynamic UI rendering
- `ASRProviderRegistry`: maps provider to config type + client factory; `capabilities` indicates availability and streaming support
- **Recognition mode**: a provider entry with a `batch` variant exposes a `recognitionMode` credential (`streaming` / `batch`, default `streaming`). Its config adopts `ASRRecognitionModeConfigurable`; use `createClient(for:config:)` and `capabilities(for:config:)` inside a session so the mode captured at start is used. Fields can be scoped with `CredentialField.visibleModes`. Synchronous batch uploads share `BufferedBatchASRClient` + a `BatchASRTranscriber` (`Sources/Type4Me/Protocol/BatchASRTranscribers.swift`).
- **Fully implemented**: Apple Speech (streaming); Volcano, StepFun, Deepgram, Cartesia, AssemblyAI, ElevenLabs, Gemini, Grok, Soniox, Bailian, Baidu, Meta Muse, Microsoft Azure MAI-Transcribe-2-Streaming, and Tencent Cloud (streaming); StepFun, Bailian, Gemini, ElevenLabs, Grok, Microsoft Azure MAI-Transcribe-2, and Tencent Cloud (selectable batch mode); MiMo, OpenAI, Groq, Mistral AI, and Custom (batch only); and Sherpa/SenseVoice when `HAS_SHERPA_ONNX` is enabled.
- **Config only (no client)**: google, aws, aliyun, iflytek
- **Custom**: user-described HTTP batch endpoint (`CustomASRConfig` + `CustomHTTPBatchTranscriber` in `Sources/Type4Me/Protocol/CustomHTTPASRProtocol.swift`). Headers and a JSON object template use `{{api_key}}`, `{{audio_base64}}` (JSON upload) or `{{audio_file}}` (multipart file part); `resultPath` locates the transcript, e.g. `results[0].transcript`.

### Adding a New Provider

1. Create a Config file in `Sources/Type4Me/ASR/Providers/`, implementing `ASRProviderConfig`
2. Write the client (implementing `SpeechRecognizer` protocol)
3. Register `createClient` in `ASRProviderRegistry.all`


### LLM Provider Inclusion Policy

- Built-in first-class LLM providers are reserved for primary foundation model vendors (e.g., OpenAI, Anthropic, Google Gemini, DeepSeek, Moonshot, Baidu, Xiaomi MiMo, Ollama, etc.) and established baseline routers (OpenRouter).
- Commercial third-party aggregation routers/gateways (such as Requesty, API Route, and similar services) should connect via the built-in **Custom OpenAI Compatible** provider (`.custom`) using their respective base URL and API key, rather than being added as dedicated first-class entries. This prevents the provider menu from turning into an uncurated directory of third-party proxy gateways. Locally running, user-owned model gateways (such as Ollama and Magpie) may be included as first-class providers.
## Local ASR Architecture (SenseVoice + Qwen3-ASR)

### Dual-Engine Design
- **SenseVoice**: Native sherpa-onnx integration (Swift), provides real-time streaming recognition (partial results as you speak). No Python dependency.
- **Qwen3-ASR** (`Sources/qwen3-asr-server/`): Python WebSocket service using MLX (Metal GPU), provides final calibration on complete audio for higher accuracy. Apple Silicon only.
- `SenseVoiceServerManager`: manages the Qwen3-ASR Python server process, auto-detects Apple Silicon vs Intel, assigns dynamic ports, saves PIDs for graceful shutdown

### Recognition Pipeline
1. `SenseVoiceASRClient` runs native sherpa-onnx recognition with Silero VAD for streaming partial results.
2. `SenseVoiceWSClient` connects to the local Qwen3-ASR Python service for speculative and final calibration.
3. Three modes: SenseVoice streaming only, Qwen3-only (final result), or hybrid (SenseVoice streaming + Qwen3 final calibration)
4. Qwen3 incremental speculative transcription with debounce for progressive results
5. `SherpaPunctuationProcessor` optionally performs CT-Transformer punctuation restoration when Sherpa is available.

### Models
- One streaming model in `ModelManager.StreamingModel`: `senseVoiceSmall` (~228MB, zh/en/yue/ja/ko)
- Auxiliary models: `offlineParaformer` (~700MB), `punctuation` CT-Transformer (~72MB), and `sileroVad` (~2MB)
- Models are stored at `~/Library/Application Support/Type4Me/models/`; most are downloaded as tar.bz2 archives, while Silero VAD is a single ONNX file.

### SherpaOnnx Integration (optional local ASR, VAD, and punctuation)
- `SherpaOnnxBridge.swift` — Swift wrapper over C API (no Obj-C bridging header needed)
- `sherpa-onnx.xcframework` — built locally via `scripts/build-sherpa.sh`, not checked into git
- `Package.swift` uses runtime detection: `hasSherpaFramework` flag conditionally defines `HAS_SHERPA_ONNX` and links SherpaOnnxLib

## Download Manager (`ModelManager`)

- Progress tracking via delegate-based `URLSession.downloadTask` (NOT async `session.download()` which doesn't report progress)
- **Resumable downloads**: captures `NSURLSessionDownloadTaskResumeData` from errors, uses `downloadTask(withResumeData:)` to resume
- Auto-retry up to N times with exponential backoff
- Active sessions stored in `activeSessions` dict for cancellation via `invalidateAndCancel()`
- Cancel clears: activeTasks, activeSessions, downloadProgress, resumeData

## Credential Storage

Credentials use a hybrid storage model:
- **Secure fields** (`isSecure: true` in CredentialField, e.g. API keys): stored in macOS Keychain (`com.type4me.grouped` / `com.type4me.scalar` services)
- **Non-secure fields** (model, language, etc.): stored in `~/Library/Application Support/Type4Me/credentials.json` (file permissions 0600)
- Auto-migration on first launch moves existing secure fields from JSON to Keychain

**Do not rely on environment variables** for credentials in production. GUI-launched apps cannot read shell env vars from `~/.zshrc`. Credentials must be configured through the Settings UI.

### credentials.json Structure (non-secure fields only)

```json
{
    "tf_asr_volcano": { "appKey": "...", "resourceId": "..." },
    "tf_asr_openai": {},
    "tf_llmModel": "...",
    "tf_llmBaseURL": "..."
}
```

API keys and other secure values are stored in Keychain, not in this file.

## Permissions Required

| Permission | Purpose |
|---|---|
| Microphone | Audio capture |
| Speech Recognition | Apple Speech recognition engine |
| Accessibility | Global hotkey listening + text injection into other apps |
| Screen Recording | Screenshots taken while dictating (⌥S / ⌥⇧S); requested on first use |

## Key Files

| Path | Responsibility |
|---|---|
| `Sources/Type4Me/ASR/ASRProvider.swift` | Provider enum + protocol + CredentialField |
| `Sources/Type4Me/ASR/ASRProviderRegistry.swift` | Registry: provider → config + client factory + capabilities |
| `Sources/Type4Me/ASR/Providers/*.swift` | Per-vendor Config implementations |
| `Sources/Type4Me/ASR/SpeechRecognizer.swift` | SpeechRecognizer protocol + LLMConfig + event types |
| `Sources/Type4Me/ASR/SenseVoiceASRClient.swift` | Native Sherpa/Silero streaming local ASR |
| `Sources/Type4Me/ASR/SenseVoiceWSClient.swift` | Qwen3-ASR speculative and final-calibration client |
| `Sources/Type4Me/ASR/VolcASRClient.swift` | Cloud streaming ASR (Volcano, WebSocket) |
| `Sources/Type4Me/ASR/DeepgramASRClient.swift` | Cloud streaming ASR (Deepgram, WebSocket) |
| `Sources/Type4Me/ASR/ElevenLabsASRClient.swift` | Cloud streaming ASR (ElevenLabs Scribe v2, WebSocket) |
| `Sources/Type4Me/ASR/StepFunASRClient.swift` | Cloud streaming ASR (StepFun, WebSocket) |
| `Sources/Type4Me/Protocol/StepFunASRProtocol.swift` | StepFun realtime wire format and response parsing |
| `Sources/Type4Me/ASR/GeminiASRClient.swift` | Cloud streaming ASR (Gemini Live API, model selectable) |
| `Sources/Type4Me/Protocol/GeminiTranscribeProtocol.swift` | Gemini Live wire format: setup/audio messages, response parsing |
| `Sources/Type4Me/ASR/GeminiConnectionGate.swift` | Gemini connection gate, close tracker, WebSocket delegate |
| `Sources/Type4Me/ASR/AzureMAIASRClient.swift` | Cloud streaming ASR (Microsoft Foundry Realtime API, MAI-Transcribe-2-Streaming) |
| `Sources/Type4Me/Protocol/AzureMAIProtocol.swift` | MAI Realtime wire format: session.update, append/commit, delta/intermediate/completed parsing |
| `Sources/Type4Me/ASR/OpenAIASRClient.swift` | Cloud batch ASR (OpenAI, REST) |
| `Sources/Type4Me/ASR/MiMoASRClient.swift` | Cloud batch ASR (Xiaomi MiMo, REST/SSE) |
| `Sources/Type4Me/ASR/TencentASRClient.swift` | Cloud streaming ASR (Tencent Cloud, WebSocket) |
| `Sources/Type4Me/Protocol/TencentASRProtocol.swift` | Tencent Cloud realtime wire format and response parsing |
| `Sources/Type4Me/Protocol/TencentRecTaskProtocol.swift` | Tencent Cloud batch task creation and polling |
| `Sources/Type4Me/Protocol/TencentCloudSigner.swift` | Tencent Cloud HMAC-SHA1 and TC3-HMAC-SHA256 signing |
| `Sources/Type4Me/Protocol/MistralASRProtocol.swift` | Mistral AI Voxtral batch transcriber (transcriptions + chat completions) |
| `Sources/Type4Me/ASR/GroqHallucinationPhrases.swift` | Groq Whisper hallucination phrase filtering |
| `Sources/Type4Me/ASR/PCMSilenceDetector.swift` | Pre-upload PCM silence and audible energy detection |
| `Sources/Type4Me/ASR/SherpaPunctuationProcessor.swift` | Optional punctuation restoration (SherpaOnnx) |
| `Sources/Type4Me/Bridge/SherpaOnnxBridge.swift` | SherpaOnnx C API Swift bridge (conditional) |
| `Sources/Type4Me/Services/SenseVoiceServerManager.swift` | Local Qwen3-ASR Python server lifecycle |
| `Sources/Type4Me/Session/RecognitionSession.swift` | Core state machine: record → ASR → inject |
| `Sources/Type4Me/Audio/AudioCaptureEngine.swift` | Audio capture, `getRecordedAudio()` returns full recording |
| `Sources/Type4Me/UI/AppState.swift` | `ProcessingMode` definition, built-in mode list |
| `Sources/Type4Me/Services/ModeStorage.swift` | Persistent processing-mode configuration and migration |
| `Sources/Type4Me/Services/RecordingDisplayProfileStore.swift` | Per-mode recording-display overrides: Follow Global uses live Global Configuration values and disables controls; off copies globals, on removes the override. Preview labels show the selected mode. |
| `Sources/Type4Me/UI/FloatingBar/FloatingBarView.swift` | Mode/action/transcript bubbles use active frosted blur with a fixed theme tint for contrast across focus changes; the main recording capsule retains native Liquid Glass. |
| `Sources/Type4Me/UI/TFButtonStyles.swift` | Settings/setup button system: `.tf(role, size:)` text buttons, `.tfIcon(kind)` icon buttons, `TFCloseButton`, `TFSpinner` (foreground-colored loading arc) |
| `Sources/Type4Me/Services/TextOutputFormatter.swift` | Shared final-output formatting, including punctuation policies |
| `Sources/Type4Me/Services/ModelManager.swift` | SenseVoice model download, validation, selection |
| `Sources/Type4Me/Services/KeychainService.swift` | Credential read/write (provider groups + migration) |
| `Sources/Type4Me/Services/HotwordStorage.swift` | ASR hotword storage (UserDefaults) |
| `Sources/Type4Me/Database/HistoryStore.swift` | Persistent transcription and processing history |
| `Sources/Type4MeIntelliSenseCore/` | Intelli Sense context, guard, and preference-learning core |
| `Sources/Type4MeReviseCore/` | Voice Revise tracking, slot targeting, and replacement core |
| `Sources/Type4Me/UI/Typo/` | Typo companion: renderer, performance state machine, voice-driven motion, cached sprites, bar and caret placement |
| `Sources/Type4Me/Services/CaretLocator.swift` | Tiered Accessibility lookup of the text caret rectangle; `CaretWatcher.swift` listens for caret/text/focus notifications |
| `Sources/Type4Me/Injection/DictationDestination.swift` | App, window, and text box locked at recording start; decides paste here / bring back / refocus / gone at delivery |
| `Sources/Type4Me/Services/DictationAttachments.swift` | Quotes and screenshots collected while recording, quote placement, delivery formatting |
| `Sources/Type4Me/Services/DictationShortcutTap.swift` | ⌥S window shot, ⌥⇧S region shot, Esc cancels the region, on its own event-tap thread |
| `Sources/Type4Me/UI/Attachments/` | Capture effects, attachment tray above the bar, region-capture overlay |
| `Sources/Type4Me/Database/HistoryMedia.swift` | Compressed screenshots and unfinished recordings kept with history entries |
| `Sources/Type4MeCorrectionCore/`, `Sources/Type4MeTransferCore/` | Selection-correction core; Mac-to-iPhone configuration transfer core |
| `iOS/` | iPhone keyboard app (XcodeGen `project.yml`, see `iOS/README.md`) |
| `Sources/Type4Me/LLM/Magpie/` | Magpie local gateway discovery, agent file parsing, model catalog, and reconciliation |
| `Sources/Type4Me/LLM/LLMProvider.swift` | 16 LLM providers, including Xiaomi MiMo, Codex CLI, local Ollama, and Magpie |
| `Sources/Type4Me/LLM/LLMProviderRegistry.swift` | LLM provider → config + client factory |
| `Sources/Type4Me/Session/SoundFeedback.swift` | Start/stop/error sounds, multiple sound styles |
| `Sources/qwen3-asr-server/server.py` | Qwen3-ASR calibration engine (MLX/Metal, Apple Silicon) |
| `scripts/dev-run.sh` | Signed Dev App build, install, and launch |
| `scripts/deploy.sh` | Build + deploy + launch |
| `scripts/build-sherpa.sh` | Build sherpa-onnx.xcframework for optional local ASR features |

## Typo Companion, Locked Target, Attachments, Network Recovery

Design documents: `docs/features/typo-companion/design.md`, `docs/features/dictation-target-and-attachments/design.md`, `docs/features/network-resilience/design.md`. Read the relevant one before changing these areas.

- **Typo** is off by default (`tf_typoCompanionEnabled`, Settings → Appearance). It never replaces the recording bar. `TypoPlacement.mode` guarantees one Typo on screen: `.bar` (peeking over the capsule) or `.caret` (in its own non-activating panel beside the text caret). When the caret cannot be read, Typo stays at the bar; standing on the text box or window was tried and withdrawn at the user's request.
- `TypoPerformance` is a pure value type driven by events and a caller-supplied clock. Keep AppKit and wall-clock reads out of it so transitions stay reproducible in tests. Both placements feed it from `AppState.barPhase`.
- Typo is drawn once per expression into sprites and moved by Core Animation layers. Do not return to per-frame vector redraw.
- A caret move means different things by stage: while the user talks it is the user moving the caret (walk); after the talking it is the text landing (leap immediately). Apps reflow text boxes without posting notifications, so the caret is also polled: 1 s while listening, 80 ms while thinking, 40 ms during a leap.
- **Locked target**: interactive dictation captures a `DictationDestination` at recording start and delivers there even if the user visits other windows. If the place cannot be brought back, the words go to the clipboard (`copiedTargetGone`); never paste into whatever is frontmost. Automation entry points keep `activateAndConfirm`.
- **Attachments** are collected only while recording. Selecting text elsewhere is a quote; selecting inside the box being dictated into is editing. Screenshots are taken only by shortcut, never by intercepting clicks. Screen Recording permission is requested on the first screenshot.
- Quotes travel through rewriting LLM modes as `⟦Qn⟧` markers that must come back exactly once.
- **Network loss**: a dropped stream keeps recording; on release the whole recording is recognized again and delivered through the normal path. Only one path may end a session. If the retry fails, the words heard so far are still delivered and the recording is kept for a week to recognize again from history.
- Typo, attachment, and network copy is bilingual and must follow the Localization rules below; Typo honours Reduce Motion.

## Development Lessons & Patterns

### Streaming ASR: Duplicate Text Prevention
- Streaming ASR emits partial results that get replaced by final results
- Must track `confirmedText` (finalized segments) separately from `currentPartial`
- Display `confirmedText + currentPartial`, replace partial on each update, append on segment finalization
- Endpoint detection signals segment boundaries

### First-Character Accuracy
- Recording start sound bleeds into first ~400ms of audio
- Solution: skip initial 6400 samples (at 16kHz) in the ASR client before feeding to recognizer
- This dramatically improves first-character recognition accuracy

### URLSession Download Progress
- `async let (url, response) = session.download(for: request)` does NOT trigger delegate progress callbacks
- Must use `session.downloadTask(with:)` + `DownloadProgressDelegate` for real-time progress
- Store URLSession reference in a dict for proper cancellation

### Large File Downloads
- Keep large binaries out of the repository; build the optional Sherpa framework locally with `scripts/build-sherpa.sh`
- For downloads >100MB, connection drops are common (error -1005)
- `NSURLSessionDownloadTaskResumeData` in error's userInfo enables resume
- Also check `NSUnderlyingErrorKey` for nested resume data

### UI Patterns
- Settings, setup, and permission buttons use `.buttonStyle(.tf(.primary | .secondary | .ghost | .destructive, size: .small | .regular | .large))` from `TFButtonStyles.swift`; primary is ink (`settingsNavActive`) and marks each surface's main action (e.g. Test Connection, Add Mode, Check for Updates); keep exactly one visible at a time by demoting the other when a Save/Download action appears. Do not hand-roll padding, fills, corner radii, or disabled opacity on a `.plain` button; the style handles hover, press, and `.disabled`. Icon-only actions use `.tfIcon(...)`, sheet dismissal uses `TFCloseButton`. List rows, segmented pickers, chips, and the floating bar keep their dedicated styles.
- Dangerous actions (delete) should require two-step confirmation (show button → confirm)
- Undownloaded items shouldn't show selection UI (radio buttons) — show download button instead
- Test/action buttons should be spatially separated from destructive actions
- Download progress UI must use `@Published` properties on `@MainActor` for SwiftUI updates

### Localization & Language Adaptation (Mandatory)
- Chinese and English are first-class product languages. Any user-facing copy in a new or changed screen, menu, popover, dialog, floating bar, indicator, or accessibility label must have Chinese and English equivalents.
- Switching `tf_language` must update every currently visible user-facing surface without an app relaunch. Persistent surfaces such as `MenuBarExtra`, floating/non-activating panels, overlays, and existing settings windows must observe the setting (for example, with `@AppStorage`) rather than capture a launch-time string.
- Persist semantic values, stable IDs, and user-entered text—not a single-language UI string as the only source of truth. Render Type4Me-provided labels at display time for the selected language.
- System-provided `ProcessingMode` names must be rendered through `localizedDisplayName` (or an explicitly equivalent language-aware API), never through the persisted raw `name`. A custom mode name or a user-renamed system mode must remain verbatim and must not be auto-translated.
- Add or update automated coverage for language-sensitive behavior, including switching between Chinese and English for changed persistent UI paths. Review both languages before declaring a UI change complete.

### Git Workflow
- `sherpa-onnx.xcframework` is not committed; `.gitignore` it and build it locally with `scripts/build-sherpa.sh`.
- Before opening or updating a PR, run `git fetch origin && git rebase origin/main` when the requested workflow calls for a rebase.
- Resolve conflicts by preserving the intended behavior from both sides and re-run the relevant tests.
- After rebasing a published work branch, update that branch with `--force-with-lease`; never use a blind force push.
- Never force-push an integration branch. Direct updates to `origin/main` require explicit user authorization.

### Package.swift Conditional Dependencies
```swift
let hasSherpaFramework = FileManager.default.fileExists(
    atPath: packageDir + "/Frameworks/sherpa-onnx.xcframework/Info.plist"
)
// Conditionally add binary target and linker settings
```
This allows the project to build even without the framework (graceful degradation).

### Sound Feedback
- `StartSoundStyle` enum: off, chime, pluck, submerge, pong, waterDrop1, waterDrop2, keyboard
- Bundled WAV files in `Sources/Type4Me/Resources/Sounds/`, copied to app bundle by deploy.sh
- Use cached `AVAudioPlayer` instances for playback
- Sound selection persisted via UserDefaults key `tf_startSound`
