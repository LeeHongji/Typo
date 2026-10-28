# Type4Me 外观预览产品设计

> 分支：`feat/appearance-preview`
> 文档类型：产品设计
> 文档状态：设计中
> 设计日期：2026-08-25
> 目标版本：Type4Me 2.x
> 对应开发设计：`docs/features/appearance-preview/development-design.md`

## 1. 背景

Type4Me 当前把录音显示、实时文本、悬停文字预览，以及标点、中文与英文之间的空白、引号样式等设置分散在“通用”页面的“录音设置”和“语音识别设置”中。

这些设置有一个共同特点：用户真正关心的不是选项本身，而是修改后 Type4Me 在使用时会变成什么样。当前设置页只能通过文字解释选项，用户必须离开设置页并实际录一次音，才能确认录音动效、实时文本和悬停预览；文本格式设置也需要在其他应用里观察最终输出。

随着未来继续增加悬浮条尺寸、透明度、颜色、字体、阴影、动画强度等外观设置，如果继续把选项放在“通用”页面，并为每一个选项各自增加小型示意图，页面会越来越拥挤，也会形成多套与真实 UI 不一致的预览实现。

因此，本功能将外观相关配置从“通用”中独立出来，新增 Settings 内的 **“外观 / Appearance”** 二级页面，并围绕一个统一、可交互、可扩展的预览区域组织这些设置。

## 2. 产品目标

### 2.1 核心目标

1. 用户修改外观相关设置后，无需离开设置页即可立即看到效果；
2. 预览尽量使用 Type4Me 的真实 UI 和真实文本格式化逻辑，而不是近似示意图；
3. 给未来新增外观配置提供统一的 Preview Stage，而不是为每个设置重复设计预览；
4. 减轻“通用”页面的信息密度，让通用设置继续聚焦设备、录音行为、系统集成和权限；
5. 保持现有设置值和持久化语义不变，用户升级后无需重新配置；
6. 中英文界面都能清楚理解各项设置及其效果。

### 2.2 成功标准

1. Settings 二级导航中出现“外观 / Appearance”；
2. 外观页面采用单栏全宽布局，不使用拥挤的左右双栏；
3. 页面顶部提供统一 Appearance Preview Stage；
4. 切换录音动效时，预览中的真实录音效果立即变化；
5. 切换“实时展示文本”时，预览浮动栏立即在实时文本与“倾听中 / Listening”之间切换；
6. 开启“悬停文字预览”后，用户把鼠标移到预览中的长文本上，可以实际触发真实 Transcript Popup；关闭后不触发；
7. 修改句末标点、盘古之白、直角引号时，文本输出区立即显示真实格式化结果；
8. 所有现有用户设置值原样保留，不发生存储 key 迁移；
9. 打开外观页面不会请求麦克风权限、启动 ASR、发送网络请求或真正录音。

## 3. 非目标

第一版不包含：

- Settings 页面左右双栏布局；
- 真实麦克风输入驱动预览；
- 在设置页启动真实 ASR；
- 录音文件或测试文本上传；
- 用户自定义预览示例文本；
- 完整主题系统；
- 自定义悬浮条颜色、透明度、尺寸、字体或阴影；
- Preview Stage 固定吸顶；
- 根据用户刚操作的设置自动滚动页面；
- 为每个设置项单独制作一套小预览；
- 把“外观”提升为左侧一级导航；
- 重新设计现有 Floating Bar 的视觉语言。

这些能力可以在统一 Preview Stage 稳定后逐步扩展。

## 4. 信息架构

### 4.1 Settings 二级导航

当前 Settings Hub 在“设置”一级入口下提供多个二级页面。本功能新增：

```text
通用 | 外观 | 模型 | 模式 | 关于
General | Appearance | Models | Modes | About
```

对于条件编译下不显示“模型”的产品版本，仍遵循现有规则，只在当前二级导航列表中插入“外观”。

“外观”属于 Settings 内部的二级页面，不增加左侧 Sidebar 一级入口。

### 4.2 为什么独立成页面

不把 Preview Stage 塞入当前“通用”页面，主要原因：

- 900pt 最小窗口宽度下，Sidebar 已占用固定空间，再增加右侧 Preview 会明显压缩设置内容；
- 外观预览需要足够宽度呈现接近真实尺寸的 Floating Bar 和 Transcript Popup；
- 外观设置未来会继续增加，独立页面能形成稳定的信息架构；
- “通用”页面可以恢复为更明确的设备、行为、系统设置集合。

## 5. 第一版设置迁移范围

### 5.1 移入“外观”的设置

#### 录音显示 / Recording Display

- 录音动效 / Visual Style
- 实时展示文本 / Live Transcript
- 悬停文字预览 / Hover Text Preview

#### 文本输出 / Text Output

- 去句末标点 / Strip Trailing Punctuation
- 盘古之白 / Pangu Spacing
- 使用直角引号 / Use Corner Quotes

这些设置虽然不全是严格意义上的“视觉皮肤”，但它们都具有强烈、直接且可解释的输出表现，适合在同一个 Preview Stage 中即时验证。

### 5.2 保留在“通用”的设置

包括但不限于：

- 麦克风选择；
- 录音时降低音量；
- 麦克风保活；
- 允许跨模式结束；
- 提示音；
- 提示音输出设备；
- 改口设置；
- 开机启动；
- Dock 图标；
- 剪贴板保留；
- 界面语言；
- 系统权限；
- 代理和调试相关高级设置。

这些配置改变行为、设备或系统集成，不属于本 Preview Stage 的主要职责。

## 6. 页面布局

外观页面使用单栏纵向布局：

```text
┌──────────────────────────────────────────────┐
│ 外观 / Appearance                            │
│                                              │
│ ┌──────────────────────────────────────────┐ │
│ │          Appearance Preview Stage        │ │
│ │                                          │ │
│ │        [ ●  实时识别文本……   × ]          │ │
│ │                                          │ │
│ │  语音识别 / Recognized Speech            │ │
│ │  我刚刚在MacBook上测试Type4Me 2.1，…      │ │
│ │                                          │ │
│ │  文本输出 / Text Output                  │ │
│ │  我刚刚在 MacBook 上测试 Type4Me 2.1，…  │ │
│ └──────────────────────────────────────────┘ │
│                                              │
│ 录音显示 / Recording Display                │
│   录音动效                        [ 电平 ▾ ] │
│   实时展示文本                    [  ●  ]    │
│   悬停文字预览                    [  ●  ]    │
│                                              │
│ 文本输出 / Text Output                      │
│   去句末标点                      [ ... ▾ ] │
│   盘古之白                        [ 开启 ▾ ] │
│   使用直角引号                    [  ●  ]    │
└──────────────────────────────────────────────┘
```

Preview Stage 位于设置项之前，让用户进入页面时先建立“下方所有调整都会反映到这里”的心智模型。

第一版 Preview Stage 不吸顶。待后续外观选项显著增加、需要长距离滚动时，再评估 sticky preview。

## 7. Preview Stage

### 7.1 定位

Preview Stage 是整个 Appearance 页面长期复用的预览画布，而不是本次六个设置的临时 Demo。

它承担两类预览：

1. **录音界面预览**：Floating Bar、实时文本、动效、悬停 Popup；
2. **文本输出预览**：原始识别文本与最终格式化文本的对照。

未来新增 Floating Bar 外观设置时，优先扩展这一 Stage，而不是新增平行预览组件。

### 7.2 录音界面预览

预览使用固定的“正在录音”场景，并持续播放合成音量变化，使动效保持活跃。

要求：

- 不读取麦克风；
- 不真正开始 RecordingSession；
- 不进行 ASR；
- 不触发文本注入；
- Finish / Cancel 控件不执行真实录音操作；
- 页面离开后停止预览计时器和动画状态。

### 7.3 录音动效

用户切换不同 Visual Style 后，Preview Stage 立即展示真实效果：

- 线条 / Lines：显示真实线条动效；
- 粒子云 / Particles：显示真实粒子效果；
- 电平 / Levels：显示真实电平效果；
- 无特效 / No Effects：保留 Floating Bar，但不显示背景动效；
- 无 / None：真实 Floating Bar 不显示。

当选择“无 / None”导致真实 Floating Bar 为空时，Preview Stage 本身仍保留，并显示轻量说明：

中文：`录音时不显示悬浮条`

英文：`The floating bar is hidden while recording.`

该说明属于 Preview Stage 的辅助文案，不伪造一个本应隐藏的 Floating Bar。

### 7.4 实时展示文本

预览必须完全反映真实行为：

- 开启：Floating Bar 显示预设的识别文本；
- 关闭：Floating Bar 显示真实的 `倾听中 / Listening` 状态。

不使用额外说明文字代替真实组件行为。

### 7.5 悬停文字预览

这是第一版必须真实可交互的能力。

预览中的识别文本应足够长，使 Floating Bar 达到真实的溢出条件。用户把鼠标移到文本区域时：

- 开启 Hover Text Preview：实际显示现有 Transcript Popup；
- 关闭：不显示 Popup；
- 鼠标移入 Popup 后，应维持现有 hover 行为；
- 鼠标离开后，遵循真实 Floating Bar 的延迟关闭行为。

不增加一个独立“显示 Popup”按钮，因为它无法验证用户真正关心的 hover 交互。

## 8. 文本输出预览

### 8.1 双区域对照

Preview Stage 中固定展示：

**语音识别 / Recognized Speech**

表示 ASR 返回、尚未经过最终格式化的文本。

**文本输出 / Text Output**

表示按照当前设置经过 Type4Me 真实文本格式化后的最终结果。

这两个区域必须同时可见，让用户直观看到“输入没有变，是输出规则改变了”。

### 8.2 示例文本

示例文本需要同时触发 CJK/Latin spacing、引号和句末标点，推荐固定使用：

```text
我刚刚在MacBook上测试Type4Me 2.1，“这个效果很好”。
```

该示例故意包含：

- 中文与英文边界；
- 英文与数字；
- 弯引号；
- 中文句末句号。

示例本身不代表 ASR 准确率，只用于格式化预览。

### 8.3 去句末标点

切换选项后立即刷新 Text Output：

- 不去掉：保留原句末标点；
- 去掉句号：去掉句末 `。` / `.`；
- 去掉所有标点：遵循当前产品已有的 trailing punctuation 语义。

预览不能单独实现另一套标点规则。

### 8.4 盘古之白

示例需要明显展示：

```text
在MacBook上测试Type4Me 2.1
```

与：

```text
在 MacBook 上测试 Type4Me 2.1
```

之间的差异。

“开启 / 关闭 / 移除空格”三种现有模式都必须使用真实 formatter 结果。

### 8.5 直角引号

开启后应直接看到：

```text
“这个效果很好”
```

变为：

```text
「这个效果很好」
```

同时遵循现有单引号转换规则，不在预览层重复实现。

## 9. 设置保存语义

外观页中的设置仍然是实际设置，而不是临时草稿。

第一版继续使用当前即时持久化行为：

- 用户修改设置；
- Preview Stage 立即更新；
- 真实 Type4Me 后续使用也立即采用新设置。

本功能不引入独立的“应用 / Apply”按钮。

现有 UserDefaults key 全部保持不变，因此升级用户不需要迁移数据。

## 10. 与真实 UI 一致性原则

Preview Stage 的可信度优先于“看起来像”。

第一版遵循：

- Floating Bar 尽可能直接复用真实 `FloatingBarView`；
- 动效复用真实 `AudioRipple`；
- Transcript Popup 复用真实 hover 逻辑；
- 文本输出复用真实 `TextOutputFormatter`；
- 只模拟状态和音量数据，不模拟最终渲染结果。

如果未来真实 UI 改版，Preview 应尽可能自动跟随，而不是需要同步维护第二套皮肤。

## 11. 状态与生命周期

进入 Appearance 页面后：

1. Preview Stage 建立固定录音演示状态；
2. 合成 AudioLevel 持续变化；
3. Floating Bar 保持可 hover 的 Recording 状态；
4. 设置变化即时重新渲染；
5. 离开页面后停止演示任务和计时器。

窗口最小化、关闭或切换 Settings 二级页面后，不应保留后台 Preview Timer。

## 12. 可访问性与本地化

- 所有新增页面标题、Section、说明、隐藏状态提示均提供中英文；
- 当前界面语言改变时，Appearance 页面和 Preview Stage 可见文案立即更新；
- Floating Bar 内已有的真实中英文行为继续复用；
- Preview Stage 的“语音识别 / 文本输出”标签需要清楚的视觉层级，不仅依赖颜色区分；
- Hover 是预览的增强交互，但所有设置仍可通过标准 macOS 控件点击或键盘操作；
- 不把 hover 作为修改设置的唯一入口。

## 13. 验收场景

### 13.1 导航与迁移

1. 打开 Settings；
2. 在二级导航看到“外观”；
3. 原“通用”页面不再出现六项已迁移设置；
4. 外观页显示原有保存值；
5. 修改后重启应用，值保持不变。

### 13.2 录音动效

依次选择全部 Visual Style，确认 Preview Stage 与真实 Floating Bar 语义一致。

### 13.3 实时文本

- 开启：显示长示例文本；
- 关闭：显示 `倾听中 / Listening`。

### 13.4 Hover Popup

- Hover Preview 开启，鼠标移入长文本后显示真实 Popup；
- 鼠标可继续移入 Popup；
- Hover Preview 关闭后不显示；
- 页面切走再回来，不应残留上一次 hover 状态。

### 13.5 文本格式

依次组合：

- 标点 3 种模式；
- Pangu spacing 3 种模式；
- Corner Quotes 开 / 关。

确认 Text Output 始终来自当前组合的真实格式化结果。

### 13.6 安全边界

打开和操作 Appearance 页面期间确认：

- 不出现麦克风授权弹窗；
- 不访问麦克风；
- 不启动 ASR；
- 不发送网络请求；
- 不修改剪贴板；
- 不向其他应用注入文本。

### 13.7 中英文

分别切换中文和英文界面，确认：

- 二级导航；
- 页面 Section；
- Preview 辅助标签；
- Floating Bar 的 `倾听中 / Listening`；
- 隐藏状态说明；

均正确刷新。

## 14. 后续演进

统一 Preview Stage 建立后，可按实际需求逐步增加：

- Floating Bar 透明度；
- 尺寸；
- 圆角；
- 阴影；
- 字体与字号；
- 动效强度；
- 动效颜色；
- Popup 宽度与高度；
- Floating Bar 屏幕位置；
- 处理状态、成功状态和错误状态预览；
- Preview Stage sticky 模式；
- 用户操作某项设置时，对应预览区域轻量强调。

新增能力应继续遵守“真实组件 + 可控演示状态”的原则。

## 15. 第一版产品决策汇总

| 项目 | 决策 |
|---|---|
| 页面层级 | Settings 内新增 Appearance 二级页面 |
| 页面布局 | 单栏全宽，不做双栏 |
| Preview 位置 | 页面顶部 |
| Preview 类型 | 统一 Preview Stage |
| Recording Preview | 真实 FloatingBarView + 合成 AudioLevel |
| Hover Preview | 真实鼠标 Hover + 真实 Transcript Popup |
| Text Preview | Raw Speech 与 Formatted Output 对照 |
| Formatter | 复用 TextOutputFormatter |
| 迁移设置 | Visual Style / Live Transcript / Hover Preview / Punctuation / Pangu / Corner Quotes |
| Storage | 完全复用现有 key，不迁移 |
| 麦克风/ASR | Preview 不使用 |
| Sticky Preview | 第一版不做 |
| 用户自定义 sample | 第一版不做 |
