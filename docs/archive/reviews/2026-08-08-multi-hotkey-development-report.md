# Type4Me 开发报告：同一 Mode 支持多个快捷键 + 设置窗口改造

> **归档文档 · 历史开发报告（2026-08-08）**：内容对应当时分支与测试快照，不代表当前代码。当前文档入口见 `docs/README.md`。

> 分支：`feat/multi-hotkey-per-mode`
> 对比基线：`main`（merge-base `5a899d9`）
> 改动规模：28 个文件，+3957 / −1288（其中 `HomeDashboardView.swift` 为新增文件）
> 已合并提交：`73f8e52 feat(ui): redesign settings experience`、`207f92a docs: refresh interface screenshots`；其余为工作区改动
> 测试状态：`swift test` 全绿（XCTest 250 项 + swift-testing 5 项，0 失败）
> 报告日期：2026-08-08

本报告面向严格的 Code Review，逐区域说明本分支（含本次会话）的全部功能改动、设计取舍、
兼容/迁移策略、已知问题与测试覆盖，并给出文件/行号定位。

---

## 0. 阅读顺序建议

1. 第 1 章「多快捷键」是核心功能，含数据模型 + 状态机 + 冲突规则三块，务必重点审。
2. 第 2 章「短文本跳过改为每 mode」涉及行为语义变化与全局→单 mode 迁移。
3. 第 3~6 章为设置窗口 UI 改造（侧栏 / mode 详情 / 首页 / 历史 / 词汇 / 设计令牌）。
4. 第 7 章 traffic-light「仿 Apple 全高侧栏」实现，纯 AppKit 桥接，单独审。
5. 第 8 章 bug 修复合集，第 9 章测试，第 10 章已知问题与建议。

---

## 1. 核心功能：同一 Mode 支持多个快捷键

### 1.1 数据模型（`Type4Me/UI/AppState.swift`）

- 新增 `HotkeyBinding`（`AppState.swift:70`）：`Codable/Identifiable/Equatable/Hashable`，
  字段 `id: UUID`、`keyCode: Int`、`modifiers: UInt64?`、`style: ProcessingMode.HotkeyStyle`。
  `init` 允许 `style` 省略，回落 `ProcessingMode.defaultHotkeyStyle`。
- `ProcessingMode`：
  - **删除**旧存储属性 `hotkeyCode / hotkeyModifiers / hotkeyStyle`，改为
    `var hotkeyBindings: [HotkeyBinding]`（`AppState.swift:98`，数量不限）。
  - 顺带新增 `var description`（首页/卡片文案）与 `var shortTextExemption`
    （每 mode 短文本跳过阈值，见第 2 章，`AppState.swift:101`）。
  - 所有内置工厂方法（direct / formalWriting / promptOptimize / defaultTranslate /
    macAction / agentMode 等）由 `hotkeyCode:...` 改为构造单元素 `hotkeyBindings`，
    并使用**稳定的 binding 种子 UUID**（`10000000-...-0000000000X`，`AppState.swift` 内
    private 常量），避免每次读取 `builtins` 都生成新 UUID 造成 churn。

### 1.2 编解码与旧数据迁移（`AppState.swift:149`、`:174`）

- `CodingKeys` 同时保留旧三键（`hotkeyCode/hotkeyModifiers/hotkeyStyle`）**仅用于解码**。
- `init(from:)` 优先级：
  1. 新数组 `hotkeyBindings` 存在 → 直接解码；
  2. 仅旧 `hotkeyCode` 存在 → 迁移为单元素绑定（带**新** UUID）；
  3. 都不存在 → 空数组 `[]`。
- `encode(to:)` **只写新数组格式**，刻意不再回写旧三键（不向下降级）。
- `description` 用 `decodeIfPresent` + `defaultDescription(for: id)`（`AppState.swift:205`）
  按稳定 mode ID 补官方文案，旧记录不含 description 时官方 mode 仍显示正确描述、
  自定义 mode 留空。

### 1.3 存储层迁移（`Type4Me/Services/ModeStorage.swift`）

- 内置 mode 合并逻辑中，原本逐字段拷贝 `hotkeyCode/Modifiers/Style` 的 3~4 处
  （direct / formalWriting / promptOptimize 迁移、`migrateSeededDefaultPrompt`）
  改为整体拷贝 `d.hotkeyBindings = mode.hotkeyBindings`，绑定数组在 prompt 迁移后不丢失。
- 同时补拷 `description` 与 `shortTextExemption`。

### 1.4 注册：一个 mode 的多个绑定共享回调（`Type4Me/Type4MeApp.swift:285`）

- `registerHotkeys` 由 `modes.compactMap { 单 binding }` 改为
  `modes.flatMap { mode -> [ModeBinding] }`：先构造该 mode 唯一的 `onStart/onStop`
  闭包，再 `mode.hotkeyBindings.map` 展开为多个 `ModeBinding`，**共享**同一对回调。
- `ModeBinding` 新增 `let bindingId: UUID`（保留 `modeId` 供跨 mode 回调解析）。
- 菜单栏 mode 列表改为展示多个绑定（首个 + `+N`，无绑定显示「未绑定」）。

### 1.5 状态机重构（`Type4Me/Input/HotkeyManager.swift`，+432/−最重）

这是本分支风险最高的一块，务必重点审。

- **状态键全部由 `modeId` 迁移到 `bindingId`**：`holdState / wasModifierDown /
  holdSafetyTimers / pendingModifierTriggers` 均按 binding 维度隔离，避免同一 mode 的
  多个绑定互相踩状态。
- **唯一活动录制**：以 `activeRecordingBindingId` + `activeRecordingModeId`
  （`HotkeyManager.swift:181`）取代旧 `activeToggleModeId`，同一时刻只允许一个录制。
- 三条事件路径（键盘 / 鼠标 / 媒体键）的 toggle 分支抽出统一入口
  `handleTogglePress(binding:)`（`:578`），显著降低重复代码与迁移出错面。
  - 空闲 → `startRecording`；同 mode 录制中 → `stopActiveRecording`；
    其他 mode → `clearActiveRecordingState` + `onCrossModeStop(modeId)`。
- hold 生命周期拆为 `handleHoldPress`（`:594`）/ `handleHoldRelease`（`:619`）：
  - 空闲按下 → 开始 hold 录制 + 安全计时器；
  - **同 mode 录制中另一绑定按下 → 立即停止，且不进入 hold 态**，使随后的松开成为 no-op
    （避免二次停止 / 意外重启）；
  - 松开仅在 `activeRecordingBindingId == 自己` 时停止。
- `resetActiveState` / `registerBindings` / `stop()` / ESC / 120s 安全超时 /
  event-tap 恢复（`recoverStuckHolds`）统一一次性清空所有 binding 级状态
  （`:811`、`:843` 等按 bindingId 定位）。

### 1.6 修饰键组合的「按整组匹配 + 吞键」（重点，本会话新增）

用户实测发现旧逻辑对 `fn` / `fn+Shift` 这类**修饰键组合**处理有误：按 `fn+Shift`
不触发目标 mode，还会触发 Shift 自身的系统行为。本分支重写为**顺序无关的整组匹配**：

- 新增 `evaluateModifierBindings(currentFlags:)`（`HotkeyManager.swift:667`）：
  在每个 `.flagsChanged` 上，用当前**全部**修饰键标志的归一化集合，与各修饰键绑定的
  `fullModifierFlags` 精确相等匹配（最多一个命中），与物理按下顺序无关。
- **吞键**：命中时返回 `nil` 吞掉事件，从而抑制 `Shift` 等修饰键自身的系统快捷键；
  未命中则 `passUnretained` 放行。
- **前缀去抖**：当 `fn` 是 `fn+Shift` 的前缀时，`fn` 的触发被延迟，给用户时间补齐更长组合；
  若随后确实补成更长组合，则静默丢弃被延迟的前缀触发（不再作为一次「点按」触发）。
- **释放瞬态过滤**：从更大组合「往下松」经过某个较小组合时（previous 是当前的严格超集），
  视为释放瞬态而非有意按下，不触发也不置为 active，保证随后的释放是干净 no-op。
- 前缀检测排除条件由 `other.modeId != binding.modeId` 改为
  `other.bindingId != binding.bindingId`（`:722` 一带），使**同一 mode 的多个绑定**也能
  正确延迟短前缀。

### 1.7 前缀触发延迟：去除 magic number（本会话）

- 旧值 `0.12s` 硬编码；改为常量 `defaultModifierPrefixTriggerDelay = 0.25`
  （`HotkeyManager.swift:204`）+ UserDefaults 覆盖键
  `modifierPrefixTriggerDelayKey = "tf_modifierPrefixTriggerDelay"`（`:207`）。
- 计算属性 `modifierPrefixTriggerDelay`（`:211`）：存在正值覆盖时取覆盖，否则取默认。
  **暂无设置 UI**，通过 `defaults write` 调整，符合用户「先参数化、页面以后再说」的要求。

### 1.8 冲突规则（`Type4Me/UI/Settings/ModesSettingsTab.swift`）

- 全局唯一：完全相同的快捷键全局仅一份；分配给其他 mode 时**只移除冲突的那一条绑定**
  （`modes[i].hotkeyBindings.removeAll { 等价 }`），保留同 mode 的其余绑定。
- 同一 mode 内不允许重复绑定：命中时禁用确认按钮并提示「已存在」，检测时排除正在编辑的绑定
  （`b.id != editing.id`）。
- 鼠标 / 媒体键等价、Fn 归一化沿用 `ModeBinding.hotkeysAreEquivalent`。
- 前缀冲突提示、Fn(63) 与音量/静音媒体键警告保留。

---

## 2. 短文本跳过：从「全局」改为「每 mode」

用户指出：短文本跳过原是绑定在 UserDefaults 单键 `tf_shortTextExemption` 上、且只对
语音润色生效的**全局**值，导致「在设置页改一个 mode，所有 mode 跟着变」。本分支改为每 mode：

- 模型新增 `ProcessingMode.shortTextExemption: Int`（`AppState.swift:101`，0 表示关闭）。
- `RecognitionSession.swift` 三处判定（早期 label 覆盖、流式停录、非流式同步路径）
  由 `currentMode.id == formalWritingId` + 读全局 UserDefaults，改为读
  `currentMode.shortTextExemption`（`RecognitionSession.swift:768/840/945` 一带）。
- **一次性迁移**（`ModeStorage.swift`）：`tf_shortTextExemptionMigrated` 标记 + 将旧全局值
  搬到语音润色 mode 上（仅当该 mode 当前阈值为 0），保留既有行为后落盘。
- UI：所有带 Prompt 模板的 mode 都能配置短文本跳过（不再仅语音润色），与「处理标签」并排展示。

---

## 3. 设置窗口信息架构与设计令牌（`DesignSystem.swift`）

- 调色板整体转为安静中性：`settingsWindowBackground` 白、`settingsSidebar`/`Active`/`Hover`
  灰阶、`settingsControl`/`Hover`/`settingsRowHover`/`settingsBorder` 统一控件填充与描边
  （`DesignSystem.swift:48` 一带）。
- 文本三级色加深、`settingsAccentBlue` 提亮为更饱和的蓝。

---

## 4. Mode 列表与详情页改造（`ModesSettingsTab.swift`，+847）

- **左侧列表精简**：更窄、去掉快捷键计数；激活态改用浅灰而非重黑；拖拽指示器与删除按钮
  默认隐藏，hover 才显示；拖拽指示器为「六个圆点」；整条列表项任意处可拖拽重排，
  删除 icon 为红色。
- **右侧详情统一**：字号/配色收敛；`key + hints` 合并为一行（hints 移到 key 右侧）；
  「处理标签」与「短文本跳过」并排；Prompt 模板置于最后。
- **快捷键胶囊**：快捷键改为与首页一致的胶囊风格，多个快捷键流式排布（`FlowLayout`），
  末尾恒为虚线「添加快捷键」胶囊；每条支持编辑（预填按键与触发方式）/ 删除。
  录制表单 `RecordingTarget` 新增 `editingBindingId`（编辑=改该绑定，新增=追加）。
- **未保存保护**：切换到别的 mode 前若有未保存改动，弹出「保存 / 放弃」选择
  （`attemptSelect` / `commitSelection` + 编辑快照比对）。
- 图标与其他页面统一（编辑/删除 SF Symbols 风格一致）。

---

## 5. 首页仪表盘（`HomeDashboardView.swift`，新增 +484）

- 「我的模式」由**实时** `appState.availableModes` 驱动，随设置排序变动同步刷新
  （修复此前首页不跟随排序的问题，见 8.1）。
- 模式卡片展示多个快捷键胶囊，空间不足时首个 + `+N`；无绑定显示「未设置」。

---

## 6. 历史页与词汇页

- 历史页（`HistoryTab.swift`，+831）：逐行懒加载、分组圆角行、展开/选择/加载更多；
  累计时长 tooltip 改用浮层控制器 `HistoryFloatingTooltipController`，修复被容器截断（见 8.2）。
- 词汇页（`VocabularyTab.swift`，+1400）：胶囊页签、内部滚动、共享搜索（同时过滤替换内容与触发词）。

---

## 7. 仿 Apple 全高侧栏与 traffic-light（`SettingsView.swift`，+497）

按用户提供的调研报告采用「保留系统原生按钮 + 内容层重绘」的稳妥路径：

- 侧栏 10pt 悬浮留白、圆角与窗口同心；`.windowStyle(.hiddenTitleBar)`。
- `WindowControlsClusterView`（`SettingsView.swift:511`，`NSViewRepresentable` 桥接）：
  - 用 `NSWindow.standardWindowButton(_:for:)` 新建三颗标准按钮，`target=nil` +
    `action = performClose/Miniaturize/Zoom`，经响应链路由，行为与原生一致；
  - `hideNativeButtons()`（`:560`）隐藏窗口真实 traffic lights，避免重影；
  - 放在 SwiftUI 内容层（非脆弱的 titlebar 层），点击/hover 稳定；
  - 定位：卡片 10pt inset 内再 `padding(.leading/top, 15)`，即距窗口边缘 25pt。
- **hover 辉光符号**（Codex 完成、用户已验证）：`mouseInside` 用 `didSet` 驱动一组
  `WindowControlGlyphView` 覆盖层显示 ×/−/+；glyph `hitTest` 返回 `nil`，把点击/缩放菜单/
  辅助功能留给底层原生按钮；`updateTrackingAreas`（`:581`）处理「重建 tracking 区时光标已在内」
  的情形（用 `mouseLocationOutsideOfEventStream` 判定）。

---

## 8. Bug 修复合集

1. **首页排序不跟随**：首页/菜单栏改用同一 `appState.availableModes`，排序变更即时同步
   （`AppState.swift` + `HomeDashboardView.swift`）。
2. **历史累计时长 tooltip 被截断**：改用浮动 panel 控制器渲染。
3. **授权后设置页高概率崩溃**：`dockIconPreferenceChanged`（`Type4MeApp.swift:507`）在
   `UserDefaults.didChangeNotification` 可能来自后台线程（tccd 跨进程同步），触碰 `NSApp`
   前先 `Thread.isMainThread` 判定并 hop 到主线程（`:514`），避免非主线程操作 AppKit 崩溃。
4. **traffic-light 热区/位置错位、hover 无符号**：见第 7 章。
5. 短文本跳过全局串改（见第 2 章）；fn+Shift 不触发且误触 Shift 系统行为（见 1.6）。

---

## 9. 测试

- `Type4MeTests/HotkeyConflictTests.swift`（+56）：同 mode 重复绑定检测（排除在编辑项）、
  同 mode 不同绑定非重复、跨 mode 转移只移除单条冲突绑定。
- `Type4MeTests/ModeStorageTests.swift`（+126）：新数组往返、空绑定往返、多 style 混合往返、
  旧三字段 JSON → 单元素绑定迁移、缺失 hotkey 字段优雅降级为空数组、description
  官方迁移/自定义留空、`description` 已写入 JSON。
- 运行结果：`swift test` 全绿（XCTest 250 + swift-testing 5，0 失败）。
- **状态机（HotkeyManager）暂无直接单测**：其核心逻辑依赖 CGEvent tap，纯逻辑（组合匹配、
  前缀判定）已通过 `ModeBinding` 静态方法在冲突测试中间接覆盖；建议评审关注（见 10）。

---

## 10. 已知问题与评审建议

1. **`settingsAccentAmber` 语义塌陷为蓝色**（承接 `2026-08-07-ui-redesign-review-report.md` 2.1）：
   `DesignSystem.swift` 中 amber 被改为与 blue 同色，但仍被大量**本轮未修改**文件用作
   「告警/进行中/强调」，会静默变蓝。建议：要么逐处改为语义正确令牌并删除 amber，
   要么恢复 amber 为独立告警色。**本报告不重复该 UI 评审，指向既有报告即可。**
2. **HotkeyManager 缺少针对新状态机的单元测试**：toggle/hold 独立启停、toggle 起 hold 停 /
   hold 起 toggle 停、第二个 hold 停后松开不重复回调、跨 mode 停止、自动重复键忽略、
   ESC/reset、hold 超时、tap 丢 key-up 恢复等，目前靠手工验收。建议抽出可注入的
   `handleTogglePress/handleHoldPress/handleHoldRelease` 纯逻辑做单测。
3. **修饰键组合 hold + fullSizeContentView 交互**：`evaluateModifierBindings` 的释放瞬态/
   前缀去抖分支较复杂，建议对照 1.6 手工回归：`fn`、`fn+Shift`、`Ctrl+Shift` 各录一次并触发。
4. **迁移一次性标记**：`tf_shortTextExemptionMigrated`、内置绑定种子 UUID 均为单向迁移，
   回滚到旧版本后再回来可能出现阈值/绑定不一致，建议在发布说明中提示。
5. 报告涉及的工作区尚未提交（仅 UI 改造 2 个提交已入），合并前请确认提交拆分与信息。
