# SenseVoice Python 解码服务设计

> **归档文档 · 已被替代（2026-03-29）**：Python SenseVoice 方案已由 2026-04-01 原生 Swift 方案替代。当前文档入口见 `docs/README.md`。

**日期**: 2026-03-29
**状态**: 已批准

## 目标

用 Python 服务替换 sherpa-onnx 的 SenseVoice 集成，获得热词 boosting、更好的标点和真正的 CTC prefix beam search 解码能力。服务打包进 DMG，开箱即用。

## 背景

- sherpa-onnx 的 SenseVoice 实现只有 greedy search，不支持热词
- 热词能力需要 CTC prefix beam search + Aho-Corasick 自动机，sherpa-onnx 只给 transducer 模型实现了
- pengzhendong/streaming-sensevoice (442 stars, Apache 2.0) 已经实现了 SenseVoice 流式推理 + 热词 boosting 的完整方案
- 用 PyInstaller 打包成独立二进制，用户无需安装 Python

## 架构

```
Type4Me.app/
├── Contents/
│   ├── MacOS/
│   │   ├── Type4Me                    ← Swift 主程序
│   │   └── sensevoice-server          ← PyInstaller 打包的 Python 服务
│   └── Resources/
│       └── Models/
│           └── SenseVoiceSmall/       ← SenseVoice 模型文件 (预打包)
```

### 通信

Swift 主程序通过 WebSocket (`ws://localhost:{动态端口}`) 与 sensevoice-server 通信。

- 客户端发送: 16kHz PCM16 二进制帧 (与现有音频管线一致)
- 服务端返回: JSON (partial/final transcript, confirmed segments, timestamps)

### Python 服务 (sensevoice-server)

基于 pengzhendong/streaming-sensevoice 改造:
- FastAPI + uvicorn WebSocket server
- 启动参数: `--model-dir`, `--port`, `--hotwords-file`
- 内置 Silero VAD + SenseVoice 流式推理 + CTC prefix beam search 热词 boosting
- 模型: FunASR SenseVoiceSmall (PyTorch 推理)

核心依赖: torch, funasr, asr-decoder, online-fbank, pysilero, fastapi, uvicorn

### 生命周期管理

- 设置选了 SenseVoice → app 启动时 spawn sensevoice-server 进程
- 设置切到其他模型 → kill 进程，释放内存
- app 退出 → kill 进程
- 健康检查: 定期 ping，进程挂了自动重启

### Swift 端

- 新建 `SenseVoiceWSClient`: 实现 `SpeechRecognizer` 协议，WebSocket 通信
- 新建 `SenseVoiceServerManager`: 管理 Python 进程启停、端口分配、健康检查
- `ASRProviderRegistry`: SenseVoice 路由到 `SenseVoiceWSClient`

### 移除内容

- 删除 `SenseVoiceASRClient.swift` (sherpa-onnx 版)
- 删除 `ModelManager` 中 SenseVoice 的下载逻辑 (改为检测 bundle 内模型)
- 删除 Silero VAD 的 AuxModelType (Python 服务自带)

### 热词配置

- Settings UI 热词编辑区 (复用现有 hotword 存储)
- 存储: `~/Library/Application Support/Type4Me/hotwords.txt`
- Python 服务启动时传入 `--hotwords-file` 路径
- 热词变更时重启 Python 服务生效

### 打包

1. `scripts/build-sensevoice-server.sh`: PyInstaller 打包 Python 服务
2. 模型文件预置在 `Resources/Models/SenseVoiceSmall/`
3. `scripts/build-dmg.sh`: 组装完整 DMG
4. 预计 DMG 大小: ~300-500MB

### 开源致谢

在 README 和 `Resources/THIRD_PARTY_LICENSES.txt` 中声明:
- SenseVoice (MIT) - FunAudioLLM/SenseVoice
- streaming-sensevoice (Apache 2.0) - pengzhendong/streaming-sensevoice
- asr-decoder (Apache 2.0) - pengzhendong/asr-decoder
