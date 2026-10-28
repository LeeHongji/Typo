# Type4Me 设置窗口 UI 改造：Code Review 报告

> **归档文档 · 历史代码审查（2026-08-07）**：内容对应当时分支快照，不代表当前代码。当前文档入口见 `docs/README.md`。

> 审查对象：`feat/new-ui` 分支相对 `HEAD (5a899d9)` 的全部工作区改动
> 参照文档：`docs/archive/reviews/2026-08-08-ui-redesign-code-review-notes.md`
> 改动规模：15 个文件，+2558 / −777，其中 `HomeDashboardView.swift` 为新增文件
> 审查日期：2026-08-07

## 1. 总体结论

本轮改造整体质量良好，信息架构、设计令牌、Modes `description` 兼容策略与自动化测试都实现得比较扎实，工作区可通过 `swift build`。文档中标注的高优先级项大多在代码中得到正确落实：

- 首页统计口径、`ViewThatFits` 响应式隐藏、重进刷新逻辑一致。
- `ProcessingMode.description` 使用 `decodeIfPresent` + 稳定 UUID 补默认描述，旧数据兼容正确，测试覆盖到位。
- 历史页逐行懒加载、分组圆角、展开/选择/加载更多在行复用下均正确；`HistoryFloatingTooltipController` 无保留环、无 Panel 泄漏、owner 作用域切换无竞态。
- 词汇页胶囊页签配色、内部滚动、共享搜索控件（同时过滤替换内容与触发词）、批量保存后的通知刷新链路正确。

未发现会崩溃的高危缺陷。以下按严重度列出应处理或至少确认的问题。

## 2. 发现清单

### 2.1 中等：设计令牌 `settingsAccentAmber` 语义塌陷为蓝色（全局副作用）

- 位置：`Type4Me/UI/DesignSystem.swift:71`
- 现状：`settingsAccentAmber` 被改为 `Color(red: 0.15, green: 0.36, blue: 0.94)`，与 `settingsAccentBlue`（:72）**完全同色**。
- 影响：`amber` 仍在大量**本轮未修改**的文件中作为“警告 / 进行中 / 强调”语义使用，这些位置会静默变成蓝色，语义与视觉都被改变：
  - `CloudSubscription/AccountTab.swift:300,314,320,359`：免费额度、额度不足告警本应是警示色，现渲染成普通蓝色。
  - `SmartCorrectionSheet.swift`（11 处，含选中项 `:328`、主按钮 `:534`）。
  - `ASRSettingsCard.swift:196,452,574`、`PermissionGuideView.swift`、`PermissionDragOverlay.swift:75`、`GeneralSettingsTab.swift:775,904`、`ModesSettingsTab.swift:339,625,638,1153`。
- 建议：二选一——
  1. 若确定要淘汰琥珀色，就把上述引用逐个改为语义正确的令牌（告警用专门的警示色、强调用 `settingsText`/`settingsAccentBlue`），并删除 `settingsAccentAmber` 以免留下同色冗余令牌；
  2. 或恢复 `settingsAccentAmber` 为独立的告警色，仅在本轮主动改造的界面改用黑/蓝。
- 说明：这是文档未覆盖的“改令牌值”带来的隐性全局回归，建议至少人工回归 `AccountTab` 的免费/告警状态观感。

### 2.2 中等：`SmartCorrectionSheet` 未随 `QuickCorrectionSheet` 统一为黑色强调

- 位置：`Type4Me/UI/Settings/SmartCorrectionSheet.swift`（选中态 `:328`、主生成按钮 `:534` 等仍用 `settingsAccentAmber`）
- 现状：文档 8.5 与本轮把 `QuickCorrectionSheet` 的选区反馈、主按钮、选中项统一改为黑色，但同为纠错入口的 `SmartCorrectionSheet` 没有同步。
- 影响：两个并列纠错弹窗视觉语言不一致；叠加 2.1 后，`SmartCorrectionSheet` 的“绿色主按钮”与选中态实际渲染为蓝色，进一步偏离设计意图。
- 建议：将 `SmartCorrectionSheet` 的选中态/主操作按钮同步为黑色（`settingsText`），与 `QuickCorrectionSheet` 对齐。

### 2.3 中等：词汇深链在搜索或应用作用域激活时静默失效

- 位置：`Type4Me/UI/Settings/VocabularyTab.swift:230-247`（`.navigateToVocabulary` 处理）
- 现状：处理器切到片段页并 `scrollTo("snippet-\(replacement)")` + 设置 `highlightedGroup`，但不清空 `searchQuery`、不重置 `selectedAppScope`。
- 影响：滚动目标 `id` 仅在该分组存在于 `displaySnippets`（受 `matchesSearch` 过滤，`:815-824`）时才存在。若当前有搜索过滤未命中该项，或正处于 app 作用域而目标是全局片段，则分组被过滤掉，滚动与高亮都成为无声 no-op。
- 建议：滚动前先 `searchQuery = ""` 且 `switchScope(to: nil)`（或切到目标所属 app 作用域），再执行 `scrollTo`。

### 2.4 中等（置信度中）：历史浮动 Tooltip 在点开纠错弹窗后可能残留

- 位置：`Type4Me/UI/Settings/HistoryTab.swift:163-179`（修饰器）、`1138-1145`（纠错动作）
- 现状：浮动 Tooltip 仅由按钮 `.onHover(false)` 或 `.onDisappear` 关闭。点击“纠错”尾按钮会在指针仍悬停于按钮时 `correctionRecord = record` 弹出模态 sheet。
- 影响：模态遮挡下被覆盖按钮不一定能收到 `onHover(false)`，且行未被移除故 `onDisappear` 不触发，`.floating` 层级的 Panel 可能残留在 sheet 之上。复制按钮（`copiedId == record.id` 保持渲染，`:1051`）也有相同窗口期。
- 建议：在尾按钮 `action` 闭包内、弹出 sheet 前无条件调用 `HistoryFloatingTooltipController.shared.hide()`。

### 2.5 低：历史浮动 Tooltip 垂直方向未做顶边 clamp

- 位置：`Type4Me/UI/Settings/HistoryTab.swift:143-146`
- 现状：`origin.x` 对左右边缘都做了 clamp，但 `origin.y` 只处理了底边（越界时翻到 `mouse.y + 18`），没有对 `screenFrame.maxY` 或顶边做约束。
- 影响：在短屏 / 副屏底部或靠近顶部时，34pt 高的 Panel 可能越出可见区域或探入菜单栏下方。
- 建议：`origin.y = min(max(origin.y, screenFrame.minY + 8), screenFrame.maxY - size.height - 8)`。

### 2.6 低：批量编辑可写入重复热词，冲击 `ForEach(id: \.self)` 身份

- 位置：`Type4Me/UI/Settings/VocabularyTab.swift:1460-1465`（`saveBulkHotwords`）、`~525`（`ForEach(displayHotwords, id: \.self)`）
- 现状：`saveBulkHotwords` 仅过滤空行、不去重；而交互式 `addHotword` 有 `hotwords.contains(word)` 去重。
- 影响：批量粘贴重复词后 `hotwords` 含重复项，`id: \.self` 产生重复 SwiftUI 身份（渲染告警/闪烁）；且 hover/删除按值匹配（`removeAll { $0 == word }`），一次删除会移除全部重复项、hover 会同时高亮多项。
- 建议：`saveBulkHotwords` 保序去重后再赋值/保存。

### 2.7 低：原生窗口按钮自定义约束的稳定性需人工回归（文档高优先级 1）

- 位置：`Type4Me/UI/Settings/SettingsView.swift:444-500`（`SettingsWindowConfigurator`）
- 观察：
  - 用带 `identifier` 前缀的约束先 deactivate 再 activate，能避免自身约束重复堆积，处理得当。
  - 但对每枚按钮强加了独立 `leading`（25/48/71）与固定 `width/height=14`，实际是自绘布局，与文档“后两枚按钮按原生间距排列”的描述略有出入（视觉无 bug，仅描述与实现不完全一致）。
  - 仅 deactivate 自己加的约束，未触及系统对这些按钮的原生约束，可能在部分 macOS 版本产生 Auto Layout 不可满足告警。
  - 进入/退出全屏时标题栏按钮 `superview` 会重建，而重配置依赖 SwiftUI 触发 `updateNSView`，全屏切换不一定触发，按钮位置在全屏进出后的稳定性建议实测。
- 建议：按文档 12.1 在多 macOS 版本、全屏进出、窗口重建场景实测；如出现告警，可在设置约束前将同批系统约束一并降级或改用 `titlebar` 布局参与而非硬约束。

## 3. 逐文件核对

| 文件 | 结论 |
| --- | --- |
| `AppState.swift` | `description` 字段、`decodeIfPresent` 回退、稳定 UUID 默认描述实现正确。✅ |
| `ModeStorage.swift` | 内置合并、旧 ID 迁移、Legacy 迁移三处均保留用户描述。✅ |
| `ModeStorageTests.swift` | 覆盖保存/重载、JSON 写入、官方 Mode 迁移、自定义留空四类场景。✅ |
| `DesignSystem.swift` | 令牌新增合理；唯 `settingsAccentAmber` 语义塌陷见 2.1。⚠️ |
| `HomeDashboardView.swift` | 统计口径与文档一致；`Task` 内回 `@State` 在 MainActor 上下文安全；`HomeDottedWaveBackground` 已在 `SettingsView:342` 挂载。✅ |
| `SettingsView.swift` | 导航/二级胶囊/回退逻辑正确；`navItem` 的 `isActive` 对 preferences 用 subtab 包含判断是设计意图非 bug；窗口配置见 2.7。✅/⚠️ |
| `VocabularyTab.swift` | 主体健壮；见 2.3、2.6。✅/⚠️ |
| `HistoryTab.swift` | 懒加载与 Tooltip 控制器主体正确；见 2.4、2.5。✅/⚠️ |
| `ModesSettingsTab.swift` | 描述编辑纳入 `isDirty`/保存/`syncFields`，两个 detail inner 均已覆盖。✅ |
| `SettingsCardHelpers.swift` | 共享 Tooltip 与卡片语言统一，主按钮改蓝。✅ |
| `QuickCorrectionSheet.swift` | 已统一黑色；但姊妹弹窗未同步，见 2.2。✅/⚠️ |
| `AboutTab/GeneralSettingsTab/ModelSettingsTab.swift` | `showsHeader` 参数化正确，嵌入时不重复标题。✅ |
| `Type4MeApp.swift` | `--open-settings` 仅 `#if DEBUG`，20 次重试上限防轮询，Release 不受影响。✅ |

## 4. 验证记录

- `swift build`：通过（工作区含新增未跟踪文件）。
- 逐文件人工审查 + 两个只读子审查（HistoryTab、VocabularyTab）。
- 未验证（建议按文档 §12/§14 人工回归）：多 macOS 版本原生按钮与全屏交互、多显示器 Tooltip 边缘、含大量同日记录的历史滚动 CPU、900×600 最窄窗口四类页面可读性、`AccountTab` 免费/告警观感（受 2.1 影响）。

## 5. 处理优先级建议

1. 先修 2.1 / 2.2：这是改动引入的跨文件视觉回归，成本低、影响面广。
2. 再修 2.3 / 2.4：属功能性静默失效与浮层残留，用户可感知。
3. 2.5 / 2.6 可随手修复；2.7 以人工回归为主。
