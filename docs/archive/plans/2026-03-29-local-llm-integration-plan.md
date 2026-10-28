# 本地 LLM (Qwen3-4B) 集成计划

> **归档文档 · 历史计划（2026-03-29）**：实现路径已经演进，不可作为当前实施清单。当前文档入口见 `docs/README.md`。

## 已完成

- [x] Qwen3-4B-Q4_K_M.gguf 下载到 `sensevoice-server/models/` (2.3GB)
- [x] llama-cpp-python 安装 (Metal GPU 加速)
- [x] server.py 加了 `/v1/chat/completions` OpenAI 兼容端点
- [x] 自动关闭 Qwen3 thinking mode (`/no_think`)
- [x] Strip `<think>` tags from output
- [x] 性能: 90 tok/s, 翻译 0.27s, 模型加载 7.4s

## 待完成

### Task 1: SenseVoiceServerManager 传 LLM 模型路径

**文件:** `Type4Me/Services/SenseVoiceServerManager.swift`

在启动参数里加 `--llm-model`:
```swift
"--llm-model", llmModelPath,  // GGUF 文件路径
```

模型路径查找逻辑:
1. App bundle: `Contents/Resources/Models/qwen3-4b-q4_k_m.gguf`
2. Dev mode: `~/projects/type4me/sensevoice-server/models/Qwen3-4B-Q4_K_M.gguf`

### Task 2: LLM 客户端自动切换 base URL

**文件:** `Type4Me/LLM/DoubaoChatClient.swift` 或对应的 LLM 客户端

当 SenseVoice server 在跑时，LLM 请求发到本地 server:
- Base URL: `http://127.0.0.1:{port}/v1`
- Model: `qwen3-4b` (server 端忽略，只有一个模型)

需要在设置 UI 加选项: 云端 LLM / 本地 LLM (Qwen3-4B)

### Task 3: 设置 UI 更新

**文件:** `Type4Me/UI/Settings/GeneralSettingsTab.swift`

LLM 配置区域加本地选项:
- 如果 LLM model 文件存在 (bundled 或 dev)，显示 "本地 LLM (Qwen3-4B)" 选项
- 选择本地时不需要 API Key
- 显示模型大小和预计速度

### Task 4: 模型预加载

LLM 模型加载需要 ~7 秒。两个策略:
- **懒加载 (推荐):** 第一次用 LLM 模式时加载，之后缓存
- **预加载:** 如果设置了本地 LLM，app 启动时就加载

server.py 已经实现了懒加载 (`_load_llm` 在首次请求时调用)。

### Task 5: 打包

- `build-sensevoice-server.sh`: requirements.txt 加 `llama-cpp-python`
- `package-app.sh`: GGUF 模型文件复制到 Resources/Models/
- DMG 大小预计: +2.3GB → 完整版 ~3.4GB

### Task 6: 测试

- 翻译模式: 说中文 → 输出英文
- Prompt 优化模式: 说 prompt → LLM 优化
- 命令模式: 语音 + 选中文字 → LLM 执行
- 切换云端/本地 LLM 来回切不出问题

## 关键文件

| 文件 | 说明 |
|------|------|
| `sensevoice-server/server.py` | 已有 `/v1/chat/completions` 端点 |
| `sensevoice-server/models/Qwen3-4B-Q4_K_M.gguf` | 模型文件 (2.3GB) |
| `Type4Me/Services/SenseVoiceServerManager.swift` | 需要加 `--llm-model` 参数 |
| `Type4Me/LLM/DoubaoChatClient.swift` | LLM 客户端，需要支持本地 base URL |
| `Type4Me/UI/Settings/GeneralSettingsTab.swift` | 需要加本地 LLM 选项 |
