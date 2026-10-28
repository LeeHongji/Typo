# Type4Me URL 录音控制功能设计

> 分支：`feat/194-url-recording-commands`
> 文档类型：产品设计
> 文档状态：已实现
> 对应 Issue：[#194](https://github.com/joewongjc/type4me/issues/194)
> 设计日期：2026-08-24
> 目标版本：Type4Me 2.x
> 对应开发设计：`docs/features/url-recording-commands/development-design.md`

## 1. 背景

Type4Me 已支持全局快捷键、鼠标键、媒体键等本地触发方式，也已经注册并处理 URL Scheme，用于打开设置、词汇管理和词表刷新等外部自动化场景。

Issue #194 的核心诉求是：让 Stream Deck、Raycast、Alfred、Hammerspoon、BetterTouchTool、macOS Shortcuts 等工具，可以**不依赖模拟键盘事件**，直接控制 Type4Me 的录音开始与结束。

目前这类工具通常只能模拟快捷键。模拟快捷键会受 Accessibility、前台应用、组合键冲突、设备驱动和系统事件分发影响，因此在硬件按钮与自动化工作流中不够稳定。

本功能将 URL Scheme 扩展为一个轻量、确定性的录音控制接口，使 Type4Me 能被外部自动化工具直接调用，同时继续复用现有录音状态机、模式系统与文本注入流程。

## 2. 产品目标与非目标

### 2.1 核心目标

第一版提供三个外部录音控制命令：

```text
type4me://start
type4me://stop
type4me://toggle
```

目标是：

1. 让外部工具可靠开始 Type4Me 录音；
2. 让外部工具可靠结束当前录音并继续既有识别、处理、注入流程；
3. 提供适合 Stream Deck 单键工作流的 toggle 行为；
4. 默认复用 Type4Me 当前选中的模式，不要求自动化工具理解内部 Mode 配置；
5. 保持与快捷键、菜单栏和浮动条一致的录音语义，不创造第二套状态机；
6. 对重复、延迟或乱序触发保持安全，避免意外丢失已录音内容。

### 2.2 成功标准

- `type4me://start` 在可开始状态下使用当前模式开始录音；
- 重复调用 `start` 不会把正在录音的 Session 停止；
- `type4me://stop` 只在准备中或录音中结束当前录音，其他状态 no-op；
- `type4me://toggle` 在空闲时开始，在准备中/录音中结束；
- 处理或恢复阶段不会因为外部命令并发启动第二轮录音；
- URL 启动后的录音仍可由现有浮动条、菜单栏或快捷键结束；
- URL 停止后的识别、LLM、历史保存和文本注入行为与快捷键停止完全一致；
- Public、Dev 和 Personal 构建继续只接受各自实际注册的 Scheme。

### 2.3 第一版非目标

第一版不包含：

- CLI executable；
- 原生 App Intents / macOS Shortcuts Action；
- AppleScript dictionary；
- 查询录音状态的 URL；
- URL 回调或 JSON 响应；
- 指定任意自定义模式；
- 用显示名称作为 Mode API 标识；
- 远程网络控制；
- 在 processing/recovering 阶段排队下一轮录音。

这些能力可以在 URL 录音控制稳定后独立演进。

## 3. 核心用户场景

### 3.1 Stream Deck 单键录音

用户把 Stream Deck 的按钮配置为打开：

```text
type4me://toggle
```

工作流：

1. 用户把输入焦点放在 ChatGPT、IDE、浏览器或其他文本输入框；
2. 按一次 Stream Deck；
3. Type4Me 使用当前模式开始录音；
4. 用户说话；
5. 再按一次 Stream Deck；
6. Type4Me 停止录音，继续原有识别、处理和注入流程。

### 3.2 Raycast / Alfred 显式 Start / Stop

对于有独立开始、结束按钮的工具，可分别绑定：

```text
type4me://start
type4me://stop
```

这种模式比 toggle 更适合可重试自动化，因为 start 和 stop 都是幂等语义。

### 3.3 macOS Shortcuts

第一版不实现原生 Shortcut Action，但系统 Shortcuts 可以使用“打开 URL”直接调用三个命令，因此已经能覆盖大多数自动化组合场景。

## 4. “当前模式”的产品定义

### 4.1 定义

`type4me://start` 中的“当前模式”定义为：

> Type4Me 当前运行时 `AppState.currentMode` 所代表的、下一次普通录音默认使用的模式。

它对应用户当前在 Type4Me 中选中的模式，并具有既有的持久化与 Provider compatibility 语义。

调用 URL 不创建 `default`、`code`、`polish` 等新的公共模式命名体系。

### 4.2 为什么第一版不支持 `?mode=name`

现有 `ProcessingMode` 的稳定身份是 UUID，显示名称可能：

- 因中英文界面不同；
- 被用户重命名；
- 与自定义模式重名；
- 随产品文案调整。

因此第一版不支持：

```text
type4me://start?mode=code
```

也不把 `ProcessingMode.name` 作为公共 API identifier。

未来如果需要指定模式，优先考虑：

```text
type4me://start?mode_id=<UUID>
```

对于内建模式，如确实需要可读 API，可另行定义长期稳定的 builtin slug；slug 必须独立于 UI 显示名称。

## 5. 命令语义

### 5.1 `start`

```text
type4me://start
```

语义：使用当前模式请求开始一轮普通录音。

状态行为：

| 当前状态 | 行为 |
| --- | --- |
| `.hidden` | 开始录音 |
| `.done` | 开始录音 |
| `.error` | 开始录音 |
| `.preparing` | no-op |
| `.recording` | no-op |
| `.processing` | no-op |
| `.recovering` | no-op |

`start` 必须是幂等命令，不能在已经录音时解释成“停止”。

### 5.2 `stop`

```text
type4me://stop
```

语义：结束当前活跃录音，并继续既有后处理流程。

| 当前状态 | 行为 |
| --- | --- |
| `.preparing` | 结束 pending start / 按现有准备期完成语义处理 |
| `.recording` | 完成录音并进入处理 |
| 其他状态 | no-op |

`stop` 不等价于“取消”。它应保留已经录到的有效内容，并走正常 finish 流程。

### 5.3 `toggle`

```text
type4me://toggle
```

| 当前状态 | 行为 |
| --- | --- |
| `.hidden` / `.done` / `.error` | 等价于 `start` |
| `.preparing` / `.recording` | 等价于 `stop` |
| `.processing` / `.recovering` | no-op |

`toggle` 是面向按钮设备的便利命令，不应该引入额外状态。

## 6. 与现有控制面的关系

### 6.1 URL 启动后仍是普通 Type4Me Session

通过 URL 启动的录音必须继续可以被：

- 浮动条完成/取消；
- 菜单栏完成/取消；
- 现有快捷键逻辑；
- ESC abort（按现有产品语义）

控制。

URL 不是新的录音 owner，只是新的 command source。

### 6.2 不模拟快捷键

URL 命令不能通过发送 CGEvent、伪造 `HotkeyBinding` 或调用 macOS 快捷键来间接触发录音。

原因：本功能的价值正是绕过模拟键盘事件的不稳定性。

## 7. 错误与反馈

第一版采用“安全 no-op + 本地诊断日志”的策略，不弹系统 Alert，不抢夺焦点。

典型场景：

- processing 时收到 start：忽略；
- 空闲时收到 stop：忽略；
- 未知 command：沿用现有 URL unknown log；
- Scheme 不属于当前安装包：沿用现有拒绝逻辑。

URL command 本身不打开 Settings，也不显示成功 toast，避免 Stream Deck 高频操作产生 UI 噪声。

如果以后需要自动化可观测性，应设计独立的状态查询/回调机制，而不是把提示框作为 API 响应。

## 8. Scheme 与构建

沿用当前构建注册：

| 构建 | Scheme |
| --- | --- |
| Public | `type4me://` |
| Dev | `type4me-dev://` |
| Personal / CtriXin | `type4me-ctrixin://` |

因此 Dev 示例为：

```text
type4me-dev://toggle
```

单个安装包只接受自己 bundle 中实际注册的 Scheme。

## 9. README 与用户文档

实现完成后，在现有 URL Scheme 章节加入：

```text
type4me://start
type4me://stop
type4me://toggle
```

并明确：

- start 使用当前 Mode；
- start/stop 是幂等语义；
- processing/recovering 时不会启动新录音；
- Stream Deck 推荐直接绑定 `toggle`；
- Shortcuts 可使用系统“打开 URL”；
- 推荐使用 `open -g 'type4me://toggle'`（`-g` 后台模式）以彻底避免前台窗口焦点切换抖动。

## 10. 焦点保护与后台调用最佳实践

### 10.1 为什么推荐 `open -g`（Background 模式）
当外部通过 macOS 普通 `open 'type4me://toggle'` 触发 URL 时，系统 LaunchServices 默认会尝试激活目标 App，导致当前正在输入的文本框短暂丢失焦点。
使用 `open -g`（`--background`）参数时，macOS LaunchServices 会纯后台派发 URL AppleEvent，**完全不激活 Type4Me 也不会转移系统焦点**，输入光标保持原地不动，实现 0 抖动、0 延迟的无缝体验。

### 10.2 Type4Me 内建焦点保障
- **URL 收到时让出焦点**：在 `AppDelegate.handleRecordingURL` 中若发现 App 处于 active 状态，立即执行 `NSApp.hide(nil)` 归还焦点给原前台应用；
- **Session 目标应用记录与激活保护**：`RecognitionSession` 在录音开始时记录前台 `targetApplication`，在最终文本注入前若目标应用未激活，自动将其激活前置（`target.activate()`），确保 `Cmd+V` 精确粘贴至原输入框。

## 11. 后续演进

### P1：指定模式

优先评估 `mode_id=<UUID>`；内建 slug 需单独定义兼容策略。

### P1：状态查询

可能形式：CLI、App Intent 或本地 IPC。URL Scheme 本身不适合返回同步结果，因此不应草率设计 `type4me://status`。

### P2：CLI

CLI 可作为 URL 或本地 IPC 的薄包装，但需要独立解决安装位置、PATH、签名和升级策略。

### P2：原生 Shortcuts / App Intents

当自动化场景需要参数选择、状态返回或 Siri 集成时，再引入 App Intents，而不是为了第一版重复 URL 能力。

## 12. 验收清单

- [x] `start` 在空闲状态使用当前 Mode 开始录音；
- [x] 重复 `start` 不结束当前录音；
- [x] `stop` 能正常结束录音并继续注入；
- [x] 空闲时 `stop` 不产生副作用；
- [x] `toggle` 可完成 Stream Deck 两次按键工作流；
- [x] processing/recovering 时所有 start/toggle-start 行为安全 no-op；
- [x] URL 启动的 Session 可被菜单、浮动条和快捷键结束；
- [x] Public / Dev / Personal Scheme 行为一致；
- [x] 焦点保持与后台调用保护生效，文本精准注入回原前台应用；
- [x] README 中英双语文档同步更新；
- [x] 不新增 CLI、App Intent 或 Mode name API。
