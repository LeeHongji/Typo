# 2026-04-03 社区 PR 合并与改造

> **归档文档 · 历史实施报告（2026-04-03）**：记录当时的合并范围，不代表当前代码状态。当前文档入口见 `docs/README.md`。

## 概述

合并了 5 个社区 PR (#99, #100, #101, #102, #103)，根据项目方向做了裁剪和改造。总计 22 个文件，+999/-245 行。

分支: `merge-community-prs` (基于 `main` 4d0aacc)

## 合入的 PR

### PR #99 — 历史记录显示 ASR 引擎名称 (jovezhong)
**完整保留。** SQLite 表新增 `asr_provider` 列，历史记录中显示每条识别使用的引擎名称（如 Deepgram、Volcano）。包含自动迁移。

### PR #100 — Deepgram 高级设置 (jovezhong)
**部分保留。** 只保留了 Deepgram 的 Numerals toggle（数字转换开关）。砍掉了:
- Deepgram 专属热词编辑框（热词统一走全局词汇表）
- `CredentialField` 的 `isTextArea` / `note` / `wordLimit` 扩展
- `settingsTextAreaField` / `textAreaWordHint` UI helpers
- `asrSummaryRows` 从方法改回 computed property

### PR #101 — ElevenLabs Scribe v2 实时 STT (jovezhong)
**完整保留。** 新增 ElevenLabs 作为流式 ASR 引擎:
- `ElevenLabsASRClient.swift` — actor-based WebSocket client
- `ElevenLabsASRConfig.swift` — API Key + 可选语言
- `ElevenLabsProtocol.swift` — 消息编解码、URL 构建
- 支持 1000 个热词（通过 URL keyterm 参数）
- 音频以 base64 JSON 发送（ElevenLabs API 要求）

### PR #102 — 隐私加固 + Keychain 迁移 (jasonwong2001)
**部分保留。** 保留了:
- API Key 从明文 JSON 迁移到 macOS Keychain（按 `CredentialField.isSecure` 拆分存储）
- 自动迁移逻辑（首次启动将旧 JSON 中的 secure 字段迁移到 Keychain）
- 日志脱敏（NSLog 不再打印识别内容和 LLM 回复原文，改为打印字符数）
- Keychain 测试用例

砍掉了:
- `PrivacyPreferences.swift` 和"云端上下文共享"开关（prompt 里写了 `{selected}` / `{clipboard}` 就是用户主动行为，不需要二次开关）
- Soniox 二次校准 UI 开关（功能本身也被删除，见下方）
- GeneralSettingsTab 高级设置区域的 UI 重构（只保留原有的"绕过代理"）
- `PromptContext.empty` 和 `referencesSensitiveVariables`

### PR #103 — 空历史 + 按钮点击区域 + 批量热词 (ShaneLevs)
**完整保留。** 三个修复:
- 录音没识别出文字时不再保存空历史记录
- 多个按钮加了 `.contentShape(Rectangle())` 扩大点击区域
- 批量热词编辑弹窗（后续被我们重构到新位置）

## 额外改动

### 删除 Soniox 二次校准死代码
- 删除 RecognitionSession 中 `sonioxAsyncTask` 相关的 20+ 行代码
- 这个功能由 `tf_sonioxAsyncCalibration` UserDefaults key 控制，但没有任何代码会写入这个 key，从未生效
- `SonioxAsyncClient.swift` 保留，因为 batch fallback（流式失败兜底）仍在使用

### 内置热词/片段替换脱钩
**热词:**
- `HotwordStorage.migrateIfNeeded()` 不再每次启动写入 `defaultHotwords` 到 `builtin-hotwords.json`
- `loadEffective()` 只返回用户热词，不再合并内置热词
- 词汇表 UI 去掉"内置 N 条热词"信息栏和文件导入流程
- 新增"批量编辑"按钮，打开文本编辑 sheet（每行一个热词）

**片段替换:**
- `SnippetStorage.migrateIfNeeded()` 不再每次启动写入 `defaultSnippets` 到 `builtin-snippets.json`
- `compiledRules()` 只编译用户片段，不再合并内置
- 词汇表 UI 去掉"内置 N 条纠正规则"信息栏
- 新增"批量编辑"按钮，格式: `替换词, 触发词1, 触发词2, ...`（每行一组）

### 批量编辑 Sheet 视觉修复
- TextEditor 加 `.scrollContentBackground(.hidden)` 消除系统白色背景
- 背景使用 `TF.settingsBg`（暖色调），边框降低不透明度
- 与整体设置界面主题一致

### CLAUDE.md 更新
- ASR Provider 枚举: 14 → 15 cases（加 elevenlabs）
- 已实现引擎列表: 7 → 8（加 ElevenLabs streaming）
- 凭证存储文档更新: 描述 Keychain 混合存储模型

## 待测试项

- [ ] 常用引擎基本录音识别
- [ ] 历史记录显示引擎名称
- [ ] 空录音不产生历史记录
- [ ] 按钮点击区域
- [ ] ElevenLabs 引擎（需要 API Key）
- [ ] Deepgram 数字转换开关
- [ ] Keychain 凭证迁移（已有 API Key 是否仍可用）
- [ ] 热词批量编辑 sheet
- [ ] 片段替换批量编辑 sheet
- [ ] 处理模式 `{selected}` / `{clipboard}` 上下文

## 待处理（GitHub）

测试通过后:
- 将 `merge-community-prs` 合入 `main`
- 更新 5 个 PR 的状态
