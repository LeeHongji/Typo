# Type4Me 紧凑型录音指示条产品设计

> 分支：`feat/compact-recording-indicator`
> 文档类型：产品设计
> 文档状态：设计中
> 设计日期：2026-08-25
> 目标版本：Type4Me 2.x
> 对应开发设计：`docs/features/compact-recording-indicator/development-design.md`

## 1. 背景

Type4Me 当前只有一套录音悬浮条外观。它会根据实时文本长度动态扩展宽度，并支持录音动效、实时展示文本、悬停文字预览、模式提示和按钮悬停提示。

这套设计适合希望获得完整录音反馈的用户，但对于已经熟悉 Type4Me、只需要确认“正在录音”以及快速结束或取消的用户，当前悬浮条占用空间较大，视觉信息也偏多。

因此，本功能把当前整套录音悬浮条定义为 **“常规 / Regular”**，并新增一套 **“紧凑型 / Compact”** 外观。Compact 是整个 Floating Bar 生命周期的 presentation，而不是只作用于录音阶段的局部皮肤：录音时使用左右操作按钮 + 动态音频指示器；录音结束后的处理、润色、恢复、完成和错误反馈也继续使用同一套 24pt 高的 Compact chrome，不再跳回 Regular。

## 2. 产品目标

1. 在“外观 / Appearance”设置中允许用户选择“常规”或“紧凑型”录音指示条；
2. 保持当前用户体验兼容：已有用户升级后默认仍为“常规”；
3. Compact 在所有可见 Floating Bar phase 中保持 24pt 高度和 Compact 视觉语言：Preparing / Recording 固定为 180 × 24 pt；Processing / Recovering / Done / Error 根据提示内容自适应宽度，不切回 Regular 尺寸；
4. 紧凑型支持录音开始时的居中模式提示（如快速模式）与按钮悬停操作提示（完成录制、取消录制 esc），但不展示实时识别文本、悬停文字预览（Transcript Popup）或现有 Regular 背景动效；
5. 录音阶段仍保留可直接点击的“完成”和“取消”操作；
6. 录音阶段由动态音频指示器反馈声音输入；Processing / Recovering / Done / Error 使用 Compact 专属的图标、进度和短状态文案；
7. 用户切换回常规后，之前设置的录音动效、实时文本和悬停预览保持原值；
8. 所有颜色继续使用 Type4Me Design Token，不在组件中写死颜色值。

## 3. 非目标

第一版不包含：

- 重新设计常规录音悬浮条；
- 用户自定义紧凑型尺寸、按钮尺寸、声纹尺寸或颜色；
- 紧凑型实时文本；
- 紧凑型 Transcript Popup；
- 紧凑型 Lines / Particles / Levels 等现有录音动效；
- 为 Compact 增加可扩展的大型后处理卡片、第二层弹窗或 55pt Regular fallback；
- 改变完成、取消、处理、恢复或录音状态机的业务语义；
- 新增独立主题系统。

## 4. 外观层级

录音显示设置拆成两个不同维度：

```text
指示条外观 / Indicator Style
├── 常规 / Regular
│   ├── 录音动效 / Visual Style
│   ├── 实时展示文本 / Live Transcript
│   └── 悬停文字预览 / Hover Text Preview
└── 紧凑型 / Compact
    ├── 录音：Finish + Audio Indicator + Cancel
    ├── 处理/润色：Compact Progress + Status
    ├── 恢复：Compact Recovery Status
    └── 完成/错误：Compact Result Feedback
```

“常规 / 紧凑型”是录音指示条的整体布局类型；“线条 / 粒子云 / 电平 / 无特效 / 无”仍然只是常规外观内部的录音动效选择。

因此，紧凑型不能被实现成新的 `RecordingVisualStyle` 项，否则会把“整体布局”和“背景动效”两个独立概念混在一起。

## 5. 设置页设计

### 5.1 新增选项

在 Settings → Appearance → “录音显示 / Recording Display”卡片第一行新增：

```text
指示条外观 / Indicator Style    [ 常规 ▾ ]
                                  [ 紧凑型 ]
```

默认值为“常规 / Regular”。

### 5.2 常规模式

选择“常规”时，现有设置全部保持可用：

- 录音动效；
- 实时展示文本；
- 悬停文字预览。

行为与当前版本一致。

### 5.3 紧凑型模式

选择“紧凑型”时：

- 录音动效设置保留显示，但置灰不可操作；
- 实时展示文本设置保留显示，但置灰不可操作；
- 悬停文字预览设置保留显示，但置灰不可操作；
- 这些设置的已保存值不被修改。

这样用户能理解这些能力只属于常规外观，同时不会因为临时切换紧凑型而丢失原来的偏好。切回常规后，三项设置恢复可用，并继续使用切换前保存的值。

## 6. 紧凑型录音指示条

### 6.1 录音态尺寸

Preparing / Recording 阶段的紧凑型录音指示条固定为：

```text
180 × 24 pt
```

180 × 24 指录音态整个紧凑型悬浮条，而不是仅指中间声纹区域。Processing / Recovering / Done / Error 不继承 180pt 固定宽度，而由提示内容决定实际宽度。所有 Compact phase 继续保持 24pt 高度、深色背景设计语言和胶囊形态。

### 6.2 布局

```text
┌──────────────────────────────────────────┐
│  [■]      dynamic audio indicator    [×] │
└──────────────────────────────────────────┘
   完成                              取消
```

- 左侧：完成 / Finish；
- 中间：动态音频指示器；
- 右侧：取消 / Cancel；
- 不放置任何文字。

### 6.3 按钮

按钮视觉尺寸为：

```text
15 × 15 pt
```

按钮主色目标为用户指定的 `#FBFBFB`，但实现必须引用现有 Design Token，而不是在 View 内写十六进制或 RGB 常量。当前 Design System 中 `TF.floatingControlLight` 已对应这一颜色，应优先复用该 token 或建立基于它的语义别名。

按钮语义：

- Finish：白色控制面，内部使用清晰的停止/完成符号；
- Cancel：白色控制面，内部使用 `×` 取消符号；
- 两个按钮继续执行与常规模式相同的业务 action；
- 15 × 15 是视觉尺寸，实际可点击区域应在 24pt 高度允许的范围内尽量扩大。

### 6.4 动态音频指示器

中间区域使用一组垂直声纹柱表达声音输入。

| 属性 | 值 |
|---|---:|
| 柱宽 | 2 pt |
| 最小高度 | 2 pt |
| 最大高度 | 18 pt |
| 非激活颜色目标 | `#8A8A8A` |
| 激活颜色目标 | `#FBFBFB` |

颜色必须使用现有 Design Token。当前 `TF.recordingTooltipBadge` 对应 `#8A8A8A`，`TF.floatingControlLight` 对应 `#FBFBFB`。

产品层不固定柱数量和柱间距；实现需要在左右按钮占位后的中间可用宽度内均匀排布，确保 2pt 柱宽和 2–18pt 高度约束不变。

### 6.5 动态语义

- 静音或输入很弱时，声纹接近最小高度，并主要使用非激活色；
- 有明确声音输入时，声纹随 `AudioLevelMeter` 动态变化，激活柱使用激活色；
- 动画连续稳定，不因 ASR 文本分段或修正发生横向尺寸变化；
- 动效只表达麦克风音量，不表达文本内容，也不复用常规模式的背景视觉效果。

## 7. 提示与气泡支持

紧凑型在录音阶段提供精简的气泡提示支持：

- **模式提示**：录音开始（Preparing / Recording 阶段）在胶囊正上方展示当前模式（如“快速模式 / Quick Mode”），2 秒后自动淡出；
- **按钮悬停提示**：鼠标悬停在左侧 Finish 按钮上方展示“完成录制 / Finish Recording”，悬停在右侧 Cancel 按钮上方展示“取消录制 esc / Cancel Recording esc”（带 esc 徽标），气泡中心与两侧 15×15 按钮对齐；
- **不展示实时文本与 Transcript Popup**：不显示实时识别文字、`倾听中 / Listening`，也不触发 Transcript 文本悬停弹窗；
- **不展示 Regular 背景动效**：不渲染 Lines / Particles / Levels 等背景波纹。

按钮继续保留完整的 accessibility label 与 action。

## 8. Compact 全生命周期状态

Compact 一旦被选中，从 Floating Bar 出现到最终隐藏，所有可见 phase 都使用同一套 **24pt 高 Compact chrome**，但宽度策略按内容类型区分。状态变化只替换内容和必要操作，不切换回 Regular。

| Phase | Compact 内容 | 宽度策略 |
|---|---|---|
| Preparing | Finish + 静态/低幅 Audio Indicator + Cancel | 固定 180pt |
| Recording | Finish + 动态 Audio Indicator + Cancel | 固定 180pt |
| Processing | Compact progress glyph + `effectiveProcessingLabel`，例如“润色中 / Polishing”“校准中 / Calibrating” | 根据内容自适应 |
| Recovering | Recovery glyph + 当前恢复状态短文案 | 根据内容自适应 |
| Done | Success icon + `feedbackMessage` | 根据内容自适应 |
| Error | Error icon + `feedbackMessage` | 根据内容自适应 |
| Hidden | 不显示 | — |

示意：

```text
Recording   [■]  ▁▃▆▂▅▇▃  [×]
Processing      ◌  润色中…
Done            ✓  已完成
Error           !  处理失败
```

所有状态维持 24pt 高度和 Compact 视觉语言。提示态宽度按 `semantic icon + 状态文本 + 可选操作 + 水平内边距` 的实际内容自然伸缩：短提示应明显短于录音态，较长提示可以自然变宽；仅当自然宽度超过最大允许宽度时才做尾部截断。完整信息继续通过 accessibility 暴露，不能因为文案较长而回退到 55pt Regular UI。

提示宽度不使用 180pt 作为最小值，也不保留类似 recording high-water mark 的历史最大宽度；状态内容变短后，胶囊应同步收窄。

Revise 完成且存在 Undo ticket 时，Done 状态把 Undo 计入自适应内容宽度；Mac Action 的 success / failure / unsure 也使用 Compact icon + message，并按实际内容自适应，而不是 Regular feedback。

## 9. 与 Regular 的 Visual Style = None 的关系

`RecordingVisualStyle.hidden` 属于常规外观设置。

因此：

- Regular + Visual Style = None → 录音时不显示常规悬浮条；
- Compact → 始终显示紧凑型指示条，不受 Regular 的 Visual Style = None 影响；
- 切回 Regular 后继续恢复此前保存的 None / Lines / Particles / Levels / No Effects 值。

## 10. Appearance Preview

设置页顶部 Preview Stage 必须真实预览当前 Indicator Style。

### Regular

继续使用现有真实 `FloatingBarView` 预览 Visual Style、Live Transcript 和 Hover Popup。

### Compact

预览直接呈现 180 × 24 紧凑型录音条：

- 左 Finish；
- 中间动态声纹；
- 右 Cancel；
- 合成 AudioLevel 继续驱动声纹；
- 不显示示例 transcript；
- 不显示 Transcript hover popup。

切换 Regular / Compact 时 Preview 立即更新。Compact Preview 如果进入 Processing / Done / Error 等 phase，必须继续保持 24pt 高的 Compact 状态反馈，并像真实 UI 一样根据提示内容自适应宽度；Preview 中出现固定 180pt 提示宽度或 55pt Regular feedback 都应视为实现错误。

## 11. 设置保存与兼容性

新增 Indicator Style 使用独立持久化值。

升级兼容原则：

- 老版本不存在该值 → 自动按 Regular 处理；
- 不迁移、不重写 `tf_visualStyle`；
- 不迁移、不重写 `tf_showLiveTranscript`；
- 不迁移、不重写 `tf_hoverTranscriptPreview`；
- Compact 只在运行时屏蔽这些能力，不修改其保存值。

## 12. 可访问性与本地化

新增用户可见文案提供中英文：

- 指示条外观 / Indicator Style；
- 常规 / Regular；
- 紧凑型 / Compact；
- 如需说明“仅常规外观可用”，同样提供中英文。

Compact 本体没有可见文字，但两个按钮继续暴露：

- `完成录制 / Finish Recording`；
- `取消录制 / Cancel Recording`。

## 13. 验收场景

### 13.1 默认兼容

已有用户升级后不修改设置，录音悬浮条外观和升级前一致，Indicator Style 显示 Regular。

### 13.2 Regular

选择 Regular 后，Visual Style / Live Transcript / Hover Preview 均可操作，现有行为保持不变。

### 13.3 Compact 基础布局

- 录音时固定 180 × 24；
- 左右按钮视觉尺寸 15 × 15；
- 中间只有动态音频指示器；
- 不显示 transcript 或 Listening 文案。

### 13.4 Compact 音频反馈

- 静音时声纹接近 2pt，呈非激活状态；
- 说话时声纹在 2–18pt 范围内变化；
- 柱宽始终 2pt；
- 激活/非激活颜色来自 Design Token。

### 13.5 Compact 能力隔离

先在 Regular 中设置任意 Visual Style 并开启 Live Transcript + Hover Preview，再切 Compact：三项设置不可操作但值不改变，Compact 不显示对应能力；切回 Regular 后旧设置和值原样恢复。

### 13.6 控件与 Preview

- 左 Finish 与常规完成行为一致；
- 右 Cancel 与常规取消行为一致；
- 非激活应用上首次点击仍可触发；
- Accessibility 可识别两个按钮；
- Settings 中 Regular / Compact 切换立即反映到 Preview；
- Compact Preview 的合成音量持续驱动声纹；
- Preview 中的 Finish / Cancel 不破坏 Demo 状态。

### 13.7 后续状态

Finish 后进入 Processing / Recovering / Done / Error 时，始终保持 24pt 高 Compact chrome，并按实际提示内容自适应宽度：

- Processing 显示紧凑进度提示 + 当前处理文案，宽度随文案变化；
- Done 显示成功 icon + feedback，短反馈自然收窄；
- Error 显示错误 icon + feedback，较长反馈可在最大宽度内自然展开；
- Revise Undo 与 Mac Action 状态仍保留必要交互/语义，并计入内容宽度；
- 提示态不以 180pt 为固定宽度或最小宽度；
- 全程不得切回 55pt Regular indicator。

## 14. 后续演进

稳定后可再评估：

- 更丰富的 Compact Processing 动效；
- 更完整的 Compact 长错误信息展开方式；
- 紧凑型尺寸档位；
- 声纹密度或灵敏度；
- 根据 Reduce Motion 调整声纹动画；
- 为视觉按钮和交互 hit target 增加更系统的 Design Token。

## 15. 第一版产品决策汇总

| 项目 | 决策 |
|---|---|
| 当前外观命名 | 常规 / Regular |
| 新外观 | 紧凑型 / Compact |
| 层级 | Indicator Style 独立于 RecordingVisualStyle |
| 默认值 | Regular |
| Compact 尺寸 | Preparing / Recording 固定 180 × 24；提示态高 24pt、宽度按内容自适应 |
| 控件 | 左 Finish、中 Audio Indicator、右 Cancel |
| 按钮视觉尺寸 | 15 × 15 pt |
| 声纹柱宽 | 2 pt |
| 声纹高度 | 2–18 pt |
| 激活色 | 复用 `TF.floatingControlLight` 对应 token |
| 非激活色 | 复用 `TF.recordingTooltipBadge` 对应 token |
| Live Transcript | Compact 不支持，保存值不改 |
| Hover Text Preview | Compact 不支持，保存值不改 |
| Recording Visual Style | Compact 不支持，保存值不改 |
| Mode / Action Hint | 录音阶段支持居中模式提示与按钮悬停气泡提示 |
| Preview | 真实组件 + 合成 AudioLevel |
| Processing / Recovery / Result | 使用 Compact 专属状态内容，不回退 Regular |
| 数据迁移 | 无；缺省即 Regular |
