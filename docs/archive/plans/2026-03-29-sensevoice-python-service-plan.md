# SenseVoice Python Service Implementation Plan

> **归档文档 · 已被替代（2026-03-29）**：Python SenseVoice 实施计划已由 2026-04-01 原生 Swift 方案替代。当前文档入口见 `docs/README.md`。

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace sherpa-onnx SenseVoice with a Python WebSocket service that supports hotwords, stream it via WebSocket to the Swift app, and package everything into a DMG.

**Architecture:** A Python service (based on pengzhendong/streaming-sensevoice) runs as a subprocess inside Type4Me.app, communicating via WebSocket. Swift sends PCM16 audio frames, Python returns JSON transcripts. PyInstaller packages the Python service into a standalone binary.

**Tech Stack:** Python (torch, funasr, asr-decoder, fastapi, uvicorn), Swift (URLSessionWebSocketTask), PyInstaller

---

## Phase 1: Python Service Setup & Validation

### Task 1: Set up Python project structure

**Files:**
- Create: `sensevoice-server/requirements.txt`
- Create: `sensevoice-server/server.py`
- Create: `sensevoice-server/README.md`

**Step 1: Create the project directory and venv**

```bash
cd ~/projects/type4me
mkdir -p sensevoice-server
cd sensevoice-server
python3 -m venv .venv
source .venv/bin/activate
```

**Step 2: Create requirements.txt**

```
asr-decoder
funasr
online-fbank
pysilero
torch
torchaudio
soundfile
fastapi[standard]
uvicorn[standard]
```

**Step 3: Install dependencies**

```bash
pip install -r requirements.txt
```

Note: This may take a while (PyTorch is large). On Apple Silicon, pip should automatically pick up the MPS-compatible torch build.

**Step 4: Verify imports**

```bash
python -c "import torch; import funasr; import asr_decoder; print('All imports OK, torch:', torch.__version__)"
```

Expected: `All imports OK, torch: 2.x.x`

**Step 5: Commit**

```bash
cd ~/projects/type4me
git add sensevoice-server/requirements.txt sensevoice-server/README.md
git commit -m "feat: add sensevoice-server Python project skeleton"
```

---

### Task 2: Port streaming-sensevoice core into our server

**Files:**
- Create: `sensevoice-server/sensevoice_model.py` (model loading + streaming inference)
- Create: `sensevoice-server/server.py` (WebSocket server)

**Step 1: Create sensevoice_model.py**

This file wraps the streaming-sensevoice logic. Port from pengzhendong/streaming-sensevoice:
- `sensevoice.py` (model registration, ~949 lines) - copy as-is with copyright header
- `streaming_sensevoice.py` (core logic, ~157 lines) - copy `StreamingSenseVoice` class

Combine into `sensevoice_model.py`:
- `StreamingSenseVoice` class with `__init__(model, contexts, beam_size, chunk_size, padding)` and `streaming_inference(samples, is_last)` generator
- Model loading via `SenseVoiceSmall.from_pretrained(model=model_dir)`
- CTCDecoder integration with hotwords

Key modifications from upstream:
- Accept `model_dir` path parameter instead of ModelScope model ID (load from local files)
- Accept `hotwords_file` path, read hotwords from file (one per line)
- Keep the `OnlineFbank` + sliding window + CTC decode pipeline intact

**Step 2: Create server.py**

WebSocket server based on the upstream `realtime_ws_server_demo.py` but simplified:

```python
#!/usr/bin/env python3
"""SenseVoice streaming ASR WebSocket server for Type4Me."""

import argparse
import asyncio
import json
import struct
import sys
from pathlib import Path

import uvicorn
from fastapi import FastAPI, WebSocket, WebSocketDisconnect

from sensevoice_model import StreamingSenseVoice, load_model

app = FastAPI()

# Global model instance (loaded once at startup)
model: StreamingSenseVoice | None = None
model_args = {}


@app.websocket("/ws")
async def websocket_endpoint(ws: WebSocket):
    await ws.accept()

    # Create a fresh session (reset decoder state)
    session = model.new_session()

    try:
        while True:
            data = await ws.receive_bytes()

            if len(data) == 0:
                # Empty frame = end of audio
                results = list(session.streaming_inference([], is_last=True))
                for r in results:
                    await ws.send_json({
                        "type": "transcript",
                        "text": r["text"],
                        "is_final": True,
                    })
                await ws.send_json({"type": "completed"})
                break

            # Convert PCM16 bytes to float samples (int16 range)
            sample_count = len(data) // 2
            samples = list(struct.unpack(f"<{sample_count}h", data))

            # Run streaming inference
            results = list(session.streaming_inference(samples, is_last=False))
            for r in results:
                await ws.send_json({
                    "type": "transcript",
                    "text": r["text"],
                    "is_final": False,
                })
    except WebSocketDisconnect:
        pass
    except Exception as e:
        try:
            await ws.send_json({"type": "error", "message": str(e)})
        except:
            pass


@app.get("/health")
async def health():
    return {"status": "ok", "model_loaded": model is not None}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--model-dir", required=True, help="Path to SenseVoiceSmall model directory")
    parser.add_argument("--port", type=int, default=0, help="Port (0 = auto-assign)")
    parser.add_argument("--hotwords-file", default="", help="Path to hotwords file (one per line)")
    parser.add_argument("--beam-size", type=int, default=3)
    parser.add_argument("--context-score", type=float, default=6.0)
    args = parser.parse_args()

    global model

    # Load hotwords
    hotwords = []
    if args.hotwords_file and Path(args.hotwords_file).exists():
        hotwords = [
            line.strip() for line in Path(args.hotwords_file).read_text().splitlines()
            if line.strip()
        ]

    # Load model
    model = load_model(
        model_dir=args.model_dir,
        contexts=hotwords if hotwords else None,
        beam_size=args.beam_size,
        context_score=args.context_score,
    )

    # Find available port if 0
    if args.port == 0:
        import socket
        with socket.socket() as s:
            s.bind(("127.0.0.1", 0))
            args.port = s.getsockname()[1]

    # Print port to stdout so Swift process can read it
    print(f"PORT:{args.port}", flush=True)

    uvicorn.run(app, host="127.0.0.1", port=args.port, log_level="warning")


if __name__ == "__main__":
    main()
```

Key protocol decisions:
- Client sends raw PCM16 bytes (same format as AudioCaptureEngine produces)
- Client sends empty bytes to signal end of audio
- Server sends JSON: `{"type": "transcript", "text": "...", "is_final": bool}` and `{"type": "completed"}`
- Server prints `PORT:12345` to stdout on startup so Swift can discover the port
- `/health` endpoint for liveness checks

**Step 3: Test the server manually**

```bash
cd ~/projects/type4me/sensevoice-server
source .venv/bin/activate
python server.py --model-dir ~/.cache/modelscope/hub/iic/SenseVoiceSmall --port 8765
```

Note: First run will download the model from ModelScope (~400MB). Subsequent runs use cache.

In another terminal, test with a wav file using a simple Python client:
```bash
python -c "
import asyncio, websockets, soundfile as sf, struct
async def test():
    audio, sr = sf.read('test.wav', dtype='int16')
    async with websockets.connect('ws://localhost:8765/ws') as ws:
        # Send audio in chunks
        for i in range(0, len(audio), 3200):
            chunk = audio[i:i+3200]
            await ws.send(struct.pack(f'<{len(chunk)}h', *chunk))
            msg = await asyncio.wait_for(ws.recv(), timeout=5)
            print(msg)
        # Send empty to end
        await ws.send(b'')
        while True:
            msg = await asyncio.wait_for(ws.recv(), timeout=5)
            print(msg)
            if '\"completed\"' in msg:
                break
asyncio.run(test())
"
```

**Step 4: Commit**

```bash
git add sensevoice-server/
git commit -m "feat: add sensevoice-server with WebSocket streaming + hotwords"
```

---

### Task 3: Test hotwords and tune parameters

**Step 1: Create a hotwords test file**

```bash
echo "Type4Me
小悠
SenseVoice" > ~/Library/Application\ Support/Type4Me/hotwords.txt
```

**Step 2: Start server with hotwords**

```bash
python server.py \
    --model-dir ~/.cache/modelscope/hub/iic/SenseVoiceSmall \
    --port 8765 \
    --hotwords-file ~/Library/Application\ Support/Type4Me/hotwords.txt \
    --beam-size 3 \
    --context-score 6.0
```

**Step 3: Test recognition with and without hotwords**

Record a test phrase containing hotwords and compare results with/without `--hotwords-file`.

**Step 4: Tune parameters if needed**

- `--beam-size`: 3 is default, try 5 for better quality (slower)
- `--context-score`: 6.0 is default, adjust if hotwords are over/under-boosted
- Chunk size / padding in the model (default 10/8) affect latency vs accuracy tradeoff

---

## Phase 2: Swift Integration

### Task 4: Create SenseVoiceServerManager

**Files:**
- Create: `Type4Me/Services/SenseVoiceServerManager.swift`

This actor manages the Python server process lifecycle.

```swift
import Foundation
import os

actor SenseVoiceServerManager {
    static let shared = SenseVoiceServerManager()

    private let logger = Logger(subsystem: "com.type4me.sensevoice", category: "ServerManager")
    private var process: Process?
    private var port: Int?

    var serverURL: URL? {
        guard let port else { return nil }
        return URL(string: "ws://127.0.0.1:\(port)/ws")
    }

    var healthURL: URL? {
        guard let port else { return nil }
        return URL(string: "http://127.0.0.1:\(port)/health")
    }

    /// Start the Python server if not already running.
    func start() async throws {
        guard process == nil else { return }

        let serverBinary = Bundle.main.executableURL!
            .deletingLastPathComponent()
            .appendingPathComponent("sensevoice-server")

        let modelDir = Bundle.main.resourceURL!
            .appendingPathComponent("Models")
            .appendingPathComponent("SenseVoiceSmall")

        let hotwordsFile = (ModelManager.defaultModelsDir as NSString)
            .deletingLastPathComponent
            .appending("/hotwords.txt")

        let proc = Process()
        proc.executableURL = serverBinary
        proc.arguments = [
            "--model-dir", modelDir.path,
            "--port", "0",  // auto-assign
            "--hotwords-file", hotwordsFile,
        ]

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice

        try proc.run()
        self.process = proc

        // Read PORT:xxxxx from stdout
        let data = pipe.fileHandleForReading.availableData
        if let output = String(data: data, encoding: .utf8),
           let portLine = output.split(separator: "\n").first(where: { $0.hasPrefix("PORT:") }),
           let portNum = Int(portLine.dropFirst(5)) {
            self.port = portNum
            logger.info("SenseVoice server started on port \(portNum)")
        }

        // Wait for health check
        for _ in 0..<30 {  // up to 30 seconds
            try await Task.sleep(for: .seconds(1))
            if await isHealthy() { return }
        }
        throw NSError(domain: "SenseVoice", code: -1,
                       userInfo: [NSLocalizedDescriptionKey: "Server failed to start"])
    }

    /// Stop the server.
    func stop() {
        process?.terminate()
        process = nil
        port = nil
        logger.info("SenseVoice server stopped")
    }

    /// Check if server is responding.
    func isHealthy() async -> Bool {
        guard let url = healthURL else { return false }
        do {
            let (_, response) = try await URLSession.shared.data(from: url)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }
}
```

**Step 1: Create the file with the above code**

**Step 2: Hook into app lifecycle**

Modify `Type4MeApp.swift` (or wherever app startup is):
- On launch: if selected ASR provider is `.sherpa` and model is `.senseVoiceSmall`, call `SenseVoiceServerManager.shared.start()`
- On settings change: if model changes, start/stop accordingly
- On quit: `SenseVoiceServerManager.shared.stop()`

**Step 3: Build and verify**

```bash
cd ~/projects/type4me && swift build 2>&1 | tail -5
```

**Step 4: Commit**

```bash
git add Type4Me/Services/SenseVoiceServerManager.swift
git commit -m "feat: add SenseVoiceServerManager for Python process lifecycle"
```

---

### Task 5: Create SenseVoiceWSClient

**Files:**
- Create: `Type4Me/ASR/SenseVoiceWSClient.swift`

Implement `SpeechRecognizer` protocol using WebSocket to the Python server. Pattern closely follows `VolcASRClient.swift`:

- `connect()`: open WebSocket to `SenseVoiceServerManager.shared.serverURL`, start receive loop
- `sendAudio()`: send raw PCM16 Data as binary WebSocket message
- `endAudio()`: send empty Data to signal end
- `disconnect()`: close WebSocket
- Receive loop: parse JSON messages, emit `RecognitionEvent.transcript` / `.completed`

Key differences from VolcASRClient:
- No authentication/headers needed (localhost)
- Simpler protocol (raw PCM16 in, JSON out, no custom binary framing)
- Server returns `{"type": "transcript", "text": "...", "is_final": bool}`

**Step 1: Create the file**

```swift
#if HAS_SHERPA_ONNX  // reuse the same compile flag for local ASR

import Foundation
import os

actor SenseVoiceWSClient: SpeechRecognizer {
    private let logger = Logger(subsystem: "com.type4me.asr", category: "SenseVoiceWS")

    private var webSocketTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var eventContinuation: AsyncStream<RecognitionEvent>.Continuation?
    private var _events: AsyncStream<RecognitionEvent>?
    private var currentText: String = ""

    var events: AsyncStream<RecognitionEvent> {
        if let existing = _events { return existing }
        let (stream, continuation) = AsyncStream<RecognitionEvent>.makeStream()
        self.eventContinuation = continuation
        self._events = stream
        return stream
    }

    func connect(config: any ASRProviderConfig, options: ASRRequestOptions) async throws {
        let (stream, continuation) = AsyncStream<RecognitionEvent>.makeStream()
        self.eventContinuation = continuation
        self._events = stream
        currentText = ""

        guard let url = await SenseVoiceServerManager.shared.serverURL else {
            throw NSError(domain: "SenseVoice", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "SenseVoice server not running"])
        }

        let session = URLSession(configuration: .default)
        let task = session.webSocketTask(with: url)
        task.resume()
        self.webSocketTask = task

        startReceiveLoop()
        eventContinuation?.yield(.ready)
        logger.info("SenseVoiceWS connected to \(url)")
    }

    func sendAudio(_ data: Data) async throws {
        guard let task = webSocketTask else { return }
        try await task.send(.data(data))
    }

    func endAudio() async throws {
        guard let task = webSocketTask else { return }
        try await task.send(.data(Data()))  // empty = end signal
    }

    func disconnect() async {
        receiveTask?.cancel()
        receiveTask = nil
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        eventContinuation?.finish()
        eventContinuation = nil
        _events = nil
    }

    private func startReceiveLoop() {
        receiveTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    guard let task = await self.webSocketTask else { break }
                    let message = try await task.receive()
                    await self.handleMessage(message)
                } catch {
                    if !Task.isCancelled {
                        await self.eventContinuation?.yield(.completed)
                    }
                    break
                }
            }
            await self.eventContinuation?.finish()
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        guard case .string(let text) = message,
              let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String
        else { return }

        switch type {
        case "transcript":
            let recognizedText = json["text"] as? String ?? ""
            let isFinal = json["is_final"] as? Bool ?? false
            currentText = recognizedText

            let transcript = RecognitionTranscript(
                confirmedSegments: isFinal ? [recognizedText] : [],
                partialText: isFinal ? "" : recognizedText,
                authoritativeText: isFinal ? recognizedText : "",
                isFinal: isFinal
            )
            eventContinuation?.yield(.transcript(transcript))

        case "completed":
            eventContinuation?.yield(.completed)

        case "error":
            let msg = json["message"] as? String ?? "Unknown error"
            eventContinuation?.yield(.error(NSError(domain: "SenseVoice", code: -1,
                                                     userInfo: [NSLocalizedDescriptionKey: msg])))
        default:
            break
        }
    }
}

#endif
```

**Step 2: Update ASRProviderRegistry**

Route SenseVoice to the new WebSocket client:
```swift
case .senseVoice:
    return SenseVoiceWSClient()
```

**Step 3: Build and verify**

**Step 4: Commit**

```bash
git add Type4Me/ASR/SenseVoiceWSClient.swift Type4Me/ASR/ASRProviderRegistry.swift
git commit -m "feat: add SenseVoiceWSClient with WebSocket communication"
```

---

### Task 6: Remove sherpa-onnx SenseVoice code

**Files:**
- Delete: `Type4Me/ASR/SenseVoiceASRClient.swift`
- Modify: `Type4Me/Services/ModelManager.swift` - change senseVoiceSmall to not require download (bundled in app)
- Modify: `Type4Me/ASR/Providers/SherpaASRConfig.swift` - remove senseVoiceModelDir, vadModelDir

**Step 1: Delete old SenseVoice client**

```bash
rm Type4Me/ASR/SenseVoiceASRClient.swift
```

**Step 2: Update ModelManager**

Change `senseVoiceSmall` to indicate it's bundled (no download needed). Update `isModelAvailable` to check Bundle resources instead of Application Support directory for SenseVoice.

**Step 3: Remove Silero VAD aux model type**

Since Python service has its own VAD, remove `sileroVad` from `AuxModelType`.

**Step 4: Build and verify**

**Step 5: Commit**

```bash
git add -A
git commit -m "refactor: remove sherpa-onnx SenseVoice, use Python service instead"
```

---

### Task 7: Integrate server lifecycle with app settings

**Files:**
- Modify: `Type4Me/Type4MeApp.swift` or app delegate
- Modify: `Type4Me/UI/Settings/GeneralSettingsTab.swift`

**Step 1: Start server on app launch if SenseVoice selected**

In app startup:
```swift
if KeychainService.selectedASRProvider == .sherpa
   && ModelManager.selectedStreamingModel == .senseVoiceSmall {
    Task { try? await SenseVoiceServerManager.shared.start() }
}
```

**Step 2: Handle settings changes**

When user changes model selection:
- Switch TO senseVoice: `await SenseVoiceServerManager.shared.start()`
- Switch AWAY from senseVoice: `await SenseVoiceServerManager.shared.stop()`
- Switch to cloud provider: `await SenseVoiceServerManager.shared.stop()`

**Step 3: Handle app quit**

In app termination: `SenseVoiceServerManager.shared.stop()`

**Step 4: Build, test manually, commit**

---

## Phase 3: Packaging

### Task 8: PyInstaller build script

**Files:**
- Create: `scripts/build-sensevoice-server.sh`

**Step 1: Create the build script**

```bash
#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/../sensevoice-server"

# Ensure venv
if [ ! -d .venv ]; then
    python3 -m venv .venv
fi
source .venv/bin/activate
pip install -r requirements.txt
pip install pyinstaller

# Build standalone binary
pyinstaller \
    --onefile \
    --name sensevoice-server \
    --hidden-import=funasr \
    --hidden-import=asr_decoder \
    --hidden-import=online_fbank \
    --collect-all funasr \
    --collect-all asr_decoder \
    server.py

echo "Built: dist/sensevoice-server"
```

**Step 2: Test the build**

```bash
bash scripts/build-sensevoice-server.sh
./sensevoice-server/dist/sensevoice-server --model-dir /path/to/model --port 8765
```

Verify it starts and responds to health checks without a Python environment.

**Step 3: Commit**

```bash
git add scripts/build-sensevoice-server.sh
git commit -m "feat: add PyInstaller build script for sensevoice-server"
```

---

### Task 9: Update deploy.sh and build-dmg.sh for full packaging

**Files:**
- Modify: `scripts/deploy.sh`
- Modify: `scripts/build-dmg.sh`

**Step 1: Update deploy.sh**

After building the Swift app, copy the sensevoice-server binary into the app bundle:
```bash
# Copy sensevoice-server binary
cp sensevoice-server/dist/sensevoice-server "$APP_BUNDLE/Contents/MacOS/"
```

**Step 2: Update build-dmg.sh**

Add model files to Resources:
```bash
# Copy SenseVoice model
mkdir -p "$APP_BUNDLE/Contents/Resources/Models/SenseVoiceSmall"
cp -r /path/to/SenseVoiceSmall/* "$APP_BUNDLE/Contents/Resources/Models/SenseVoiceSmall/"
```

**Step 3: Test full build + DMG creation**

```bash
bash scripts/build-sensevoice-server.sh
bash scripts/build-dmg.sh
```

Open the DMG, drag app to Applications, launch, verify SenseVoice works with hotwords.

**Step 4: Commit**

```bash
git add scripts/deploy.sh scripts/build-dmg.sh
git commit -m "feat: integrate sensevoice-server into app bundle and DMG build"
```

---

### Task 10: Add THIRD_PARTY_LICENSES.txt

**Files:**
- Create: `Type4Me/Resources/THIRD_PARTY_LICENSES.txt`

Include full license texts for:
- SenseVoice (MIT) - FunAudioLLM
- streaming-sensevoice (Apache 2.0) - pengzhendong
- asr-decoder (Apache 2.0) - pengzhendong
- FunASR (MIT) - modelscope

Update deploy.sh to copy this file into the app bundle Resources.

**Step 1: Create the file and commit**

```bash
git add Type4Me/Resources/THIRD_PARTY_LICENSES.txt
git commit -m "docs: add third-party license attributions"
```
