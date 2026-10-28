# Code Review：`feat/multi-hotkey-per-mode` 分支

> **归档文档 · 历史代码审查（2026-08-08）**：内容对应当时分支快照，不代表当前代码。当前文档入口见 `docs/README.md`。

> 审查对象：`feat/multi-hotkey-per-mode` 工作区改动（+28 文件，基线 `main`）
> 依据：`docs/archive/reviews/2026-08-08-multi-hotkey-development-report.md`
> 构建状态：`swift build` 全绿
> 报告日期：2026-08-08（已根据反馈修订）

对工作区改动做详尽审查。整体评价：**功能完成度高，数据迁移设计周到，状态机重构符合多绑定语义。存在 1 个必须修复的状态机清理缺陷，以及 observer 泄漏、状态机测试缺失等需在合并前后处理的问题。**

修订说明：上一版曾把 `UserDefaults` 跨线程读列为 P1，经核实为误判（`UserDefaults` 线程安全，且事件 tap 回调运行在主线程）；曾把本地 `modes` 与 `appState.availableModes` 双写列为 P2 功能风险，经核实 `availableModes` 为普通存储属性、无自定义 setter 也不会被 reconcile 回写，风险被夸大，已降为架构备注。详见各条。

---

## P0 — 必须修复

### 1. 录制停止/切换时未统一清理 active binding 的 hold 状态与安全计时器

**根因位置**：`HotkeyManager.swift:637` `clearActiveRecordingState()` 与 `stopActiveRecording()` —— 它们只清 `activeRecordingBindingId / activeRecordingModeId`，**从不**触碰被切走 binding 的 `holdState[bindingId]` 与 `holdSafetyTimers[bindingId]`。

**影响范围（比初版判断更宽）**：只要当前录制由 hold binding 启动，随后通过以下任一路径停止，都可能残留 `holdState[id] == true` 与正在滴答的 120s safety timer：

- 同 mode 的另一个 hold / toggle 按下（`handleHoldPress` / `handleTogglePress` 的「同 mode」分支只 `stopActiveRecording`）；
- 跨 mode 的 toggle 按下（`handleTogglePress` 跨 mode 分支只 `clearActiveRecordingState` + `onCrossModeStop`）；
- 跨 mode 的 hold 按下（`handleHoldPress` 跨 mode 分支同上）。

残留计时器到点触发 `handleHoldSafetyTimer`（`:840`）：`guard holdState[id] == true` 仍成立 → 走 `binding.onStop()` 分支再次停止一个已经不在录制的 session，产生**非预期的二次停止回调**。这与报告 1.5「同 mode 录制中按下不重启」对 hold 的对称保证相违。

**建议（统一清理，而非分支补丁）**：在录制生命周期的**统一停止点**清理 active binding 的 hold 侧状态。最小改动是让 `stopActiveRecording()` / `clearActiveRecordingState()` 在丢掉 active binding 前，先把它的 hold 标志与计时器清掉：

```swift
private func stopActiveRecording() {
    guard let active = activeRecordingBinding() else {
        clearActiveRecordingState()
        return
    }
    // 清理该 binding 的 hold 侧状态，避免跨 binding/跨 mode 切换后残留计时器
    holdState[active.bindingId] = false
    cancelSafetyTimer(for: active.bindingId)
    clearActiveRecordingState()
    active.onStop()
}
```

同样适用于 `handleHoldSafetyTimer` 自身已 invalidate、以及 `recoverStuckHolds` 的对称路径（后者已各自清，OK）。

**并补状态机单测**：覆盖「hold 录制中 → 同 mode 第二 binding / 跨 mode toggle / 跨 mode hold 任一按下」三条路径，断言 `holdState`、`holdSafetyTimers`、二次回调次数。这是本分支合并前**最值得补**的测试。

---

## P2 — 建议处理

### 2. `Type4MeApp.swift:408` — `UserDefaults.didChangeNotification` observer 在 `registerHotkeys` 里叠加注册、且不保存 token

每次 `registerHotkeys(for:)`（ASR provider 切换、`modesDidChange` 都会触发）都新增一个 observer，没有先 remove 上次的。结果 provider 切换 N 次后累计 N 个 observer，随任意 setting 落盘全部触发。

**影响修正**：当前回调只调用 `syncESCAbortSetting()`，而该方法固定赋值 `true`，所以后果是 **observer 泄漏 + 重复空操作**，不会放大 `dockIconPreferenceChanged` 竞态（上一版的「放大竞态」判断过强，已删除）。`dockIconPreferenceChanged` 自身的主线程 hop（报告 8.3）方向正确。

另外：当前 `syncESCAbortSetting()` 实际只是固定赋 `true`，该 observer 目前**没有实际语义**。

**建议**：要么移到启动阶段（`applicationDidFinishLaunching`）注册一次且持有 token；要么直接删除这个空操作 observer。降为 P2（功能不崩，属资源卫生）。

### 3. `HotkeyManager` 状态机无单测（报告 10.2 自认，修正表述）

- `handleTogglePress` / `handleHoldPress` / `handleHoldRelease` 全是 `private`，无法注入测试；
- 报告 §9 称「核心逻辑已通过 `ModeBinding` 静态方法在冲突测试中间接覆盖」——**表述过强**。`HotkeyConflictTests` 只覆盖 `ModeBinding` 的纯函数（快捷键等价、前缀判断）；`handleToggle/Hold` 的跨 binding / 跨 mode 行为（含本 review 的 P0 路径）**完全没有**测试覆盖。

**建议**：抽出一个 `HotkeyStateReducer` 纯 struct（输入 `[ModeBinding]` + `inout State` + 一个事件枚举），让 `HotkeyManager` 只负责 CGEvent→枚举映射 + 回调派发。需覆盖：toggle/hold 独立启停、toggle 起 hold 停 / hold 起 toggle 停、第二 hold 停后松开不重复回调、跨 mode 停止、自动重复键忽略、ESC/reset、hold 超时、tap 丢 key-up 恢复。这是合并前**最值得补**的工程能力账，直接能挡住 P0 那类回归。

### 4. `evaluateModifierBindings` 释放瞬态分支复杂度过高（维护性，非已知 bug）

`HotkeyManager.swift:680-706` 一段同时处理：①释放旧 combo ②吞掉被中断的前缀触发 ③`consumePendingModifierRelease` 合成 press+release ④「从更大 combo 往下松」的瞬态过滤。四个语义混在一个函数里，仅靠 `shouldSwallow` 一个布尔返回值。实现符合报告 1.6 描述，但易在后续迭代中被改坏。

**建议**：按生命周期拆 `releaseActiveComboIfNeeded()` / `detectReleaseTransient()` / `pressComboIfNeeded(deferred:)`，各自可单测。属维护性建议，不是已知功能错误。

---

## P3 — 小问题 / 体验

### 5. `Type4MeApp.swift:779` 菜单栏 mode 列表用 `joined(separator: " / ")` 平铺所有快捷键

功能正确，但 5+ 绑定时菜单条目会很长、可能溢出菜单宽度。HomeDashboard 用了 `prefix(2) + "+N"` 的合理降级，菜单栏没有对齐。**同时**：开发报告 §1.4 / §5 写成「首个 + `+N`」，与实际代码（`joined(" / ")` 全平铺）**不一致** —— 报告需修订为实际实现。

**建议**：菜单栏也走 `visible + (+N with tooltip)` 模式；或至少 `prefix(3)` 截断，并据实更新开发报告。

### 6. `ModeStorage.swift:71` — `migrateDefaultMode` 命名可加注释

`migrated.isBuiltin = false` 表明只迁移 builtin→detachable 场景，配合 `guard mode.isBuiltin || mode.prompt.isEmpty` 兼容性 OK。建议加注释说明「builtin 一旦被用户改 prompt 就转为可删除」，降低未来误读风险。

### 7. `ModeStorage.swift:118-122` — `tf_agentModeSeeded` 标记语义（健壮性，非 bug）

现有注释明确表达「一次补种，之后尊重用户删除」。当 agent mode 已存在时设置完成标记是**正确**行为（不重复补种）；「只要缺失就永远重新添加」反而会破坏用户主动删除模式的语义。唯一可讨论：`save(result)` 失败时仍设置标记 —— 最多是迁移健壮性，不构成 P1。

### 8. 测试覆盖缺口

`ModeStorageTests.swift`（+37）覆盖了：往返、空绑定、多 style 混合、旧三字段迁移、缺字段降级、description 迁移/留空——充分。**缺**：

- **旧三字段 + 新数组同时存在的混合 JSON** 的迁移优先级测试（`init(from:)` 明确优先新数组，但没测）。
- `shortTextExemption` 一次性迁移**未单测**——建议加：旧 `tf_shortTextExemption` 全局值，在 `formalWriting.id` 的 mode 上、且当前阈值为 0 时，应被搬到 `mode.shortTextExemption`，且标记已置；第二次 `load()` 不再迁移。

### 9. 提交拆分（报告 10.5）

仅 2 个 commit 已入工作树（UI 改造 + 截图），**多快捷键核心 + 短文本迁移 + HotkeyManager 重构全部堆在工作区未提交**。合并前务必拆分：①数据模型+迁移 ②状态机 ③设置 UI ④Home/History/Vocabulary ⑤traffic-light。否则 reviewer 无法逐 commit 审、回滚粒度丧失。

---

## 架构备注（已降级，非问题）

- 本地 `@State modes` 与 `appState.availableModes` 双写：`availableModes` 为普通存储属性、无自定义 setter、无 `didSet`，也不会被 `reconcileCurrentMode` 回写（后者只改 `currentMode`）。本地草稿是未保存保护所需要的。当前不存在「两份不同步快照」的功能风险，无需改。（上一版误判为 P2 功能风险，已订正。）
- `HomeDashboardView.swift:21` `private var modes` 访问：Swift `Array` copy-on-write，这里通常只是共享 buffer，不构成性能问题。（上一版「整数组拷贝」判断错误，已删除。）
- `DesignSystem.swift:79-85` amber 语义塌陷：本次未改动的 `builtinModeDetail`/`FormalWritingDetailInner` 仍用 `settingsAccentAmber` 作图标色，而 amber 已不是独立告警色。指向既有 `2026-08-07-ui-redesign-review-report.md`，本次不重复。

---

## 开发报告需同步修订的三处

| 章节 | 现状 | 应改为 |
|---|---|---|
| §1.4 / §5 | 「菜单栏/卡片展示首个 + `+N`」 | 实际菜单栏为 `joined(" / ")` 全平铺；卡片才是 prefix+`+N` |
| §7 | `×/−/+` | 第三 glyph 是缩放箭头 `arrow.up.left.and.arrow.down.right`（zoom glyph），统一写成「× / − / zoom glyph」 |
| §9 | 「核心逻辑已通过 `ModeBinding` 静态方法间接覆盖」 | 表述过强：仅覆盖快捷键等价与前缀判断辅助函数，状态机行为未覆盖 |
| §10.3 | 「修饰键组合 hold + `fullSizeContentView` 交互」 | `fullSizeContentView` 与修饰键状态机无关，应改为「修饰键组合 hold/toggle 手工回归」 |

---

## 总结表

| 级别 | 数 | 关键项 |
|---|---|---|
| P0 | 1 | 录制停止/切换路径未统一清理 hold 状态与 safety timer → 120s 后幽灵回调 |
| P1 | 0 | （`UserDefaults` 跨线程读经核实为误判，已删除） |
| P2 | 3 | observer 叠注册且空操作；状态机无单测（含需测 P0 路径）；modifier 分支复杂度 |
| P3 | 5 | 菜单栏平铺、migrateDefaultMode 注释、agentMode 标记健壮性、测试缺口、提交拆分 |

---

## 整体结论

核心数据模型（`HotkeyBinding`、`ProcessingMode.Codable`、`ModeStorage` 迁移）设计扎实，测试充分；冲突检测、前缀判定、旧三字段迁移的实际代码与测试一致。状态机重构方向正确：bindingKey 维度隔离状态、统一 `handleTogglePress` 入口、修饰键整组匹配 + 吞键的实现都符合报告所述。

主要风险集中在**录制生命周期的统一清理**：P0 正是缺单测就会漏掉的那类回归。

**建议合并路径**：先修 P0（统一清理 hold 状态 + 计时器）→ 抽 `HotkeyStateReducer` 补状态机单测（覆盖跨 mode / 第二 hold 松开 / 安全计时器 / ESC / tap 恢复）→ 处理 observer 重复注册 → 同步修订开发报告 4 处 → 拆提交 → 合并。
