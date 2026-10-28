# Issue #144 测试方案：历史记录卡顿、白屏、内存持续上涨

> **归档文档 · 历史问题测试（2026-04-26）**：仅用于追溯 Issue #144，不代表当前性能基线。当前文档入口见 `docs/README.md`。

> 关联 Issue: https://github.com/joewongjc/type4me/issues/144
>
> 用户报告：在查看历史记录时，出现内存持续上升、白屏、卡顿等问题。内存占用在滚动后约 1 分钟内达到 1+ GB；翻动卡顿可复现；白屏可复现。

## 0. 根因摘要

三层叠加：

| 层 | 问题 | 文件位置 |
|---|---|---|
| L1 (放大器) | `ForEach` 内 `if let` / `if` 让每行 view 数量在 N/N+1 间摆动 → SwiftUI 走 **slow path**，无法 lazy diff，每次滚动 / 状态变化全量重绘 | `HistoryTab.swift:689` (`recordCard`) |
| L2 (重活) | `groupedRecords` computed property 每次 body 求值都重算；`DayGroup.title` 每次都新建 `DateFormatter`；`copiedId` 改变触发整个 body 重渲 | `HistoryTab.swift:159, 142, 83` |
| L3 (累积) | `textSelection(.enabled)` 在 macOS LazyVStack 上有资源不释放问题 | `HistoryTab.swift:720, 731` |

修复目标：先关 L1 slow path，再缓存 L2 重活，最后视情况处理 L3。

---

## 1. 测试环境与准备

### 1.1 环境
- macOS 14+（用户可能在更高版本，按本地为准）
- Type4Me Cloud variant（当前 deploy.sh 默认产物）
- Activity Monitor、Console.app 常驻

### 1.2 测试数据：≥ 1500 条 history records

用户的统计是 37,251 字 / 165 字每分 ≈ 750–1500 条记录。我们按 1500 条上限测，确保问题可稳定复现。

如果本地数据不够，用下面的脚本批量插假数据（跑前先备份 `~/Library/Application Support/Type4Me/history.db`）：

```bash
# 备份
cp ~/Library/Application\ Support/Type4Me/history.db \
   ~/Library/Application\ Support/Type4Me/history.db.bak

# 注入 1500 条覆盖最近 30 天的假记录
python3 - <<'PY'
import sqlite3, uuid, random
from datetime import datetime, timedelta, timezone

db = sqlite3.connect(
    "/Users/jonathan/Library/Application Support/Type4Me/history.db"
)
cur = db.cursor()
now = datetime.now(timezone.utc)
modes = ["默认", "公文", "编程辅助", None]
providers = ["volcano", "deepgram", "sensevoice", None]
for i in range(1500):
    delta = timedelta(minutes=random.randint(0, 30 * 24 * 60))
    ts = (now - delta).isoformat()
    text = "测试样本 " + ("内容 " * random.randint(3, 40))
    cur.execute("""
        INSERT INTO recognition_history
        (id, created_at, duration_seconds, raw_text, processing_mode,
         processed_text, final_text, status, character_count, asr_provider)
        VALUES (?, ?, ?, ?, ?, ?, ?, 'completed', ?, ?)
    """, (
        str(uuid.uuid4()), ts, random.uniform(1.0, 30.0), text,
        random.choice(modes),
        text if random.random() > 0.5 else None,
        text, len(text), random.choice(providers)
    ))
db.commit()
db.close()
print("done")
PY

# 还原
# mv ~/Library/Application\ Support/Type4Me/history.db.bak \
#    ~/Library/Application\ Support/Type4Me/history.db
```

### 1.3 工具

| 工具 | 用途 |
|---|---|
| Activity Monitor | 内存峰值、Not Responding 状态 |
| Console.app | `ForEach` slow-path 日志 |
| Instruments → Time Profiler | 主线程 CPU 热点（DateFormatter, startOfDay） |
| Instruments → Allocations | 持续上涨的对象类型 |
| 计时（手机秒表） | 复现"1 分钟内涨到 1GB"的时间窗 |

---

## 2. 定位问题：修复前必须复现的测试 (Before)

每个 case 跑两遍：第一遍记录现象，第二遍用 Instruments / Console.app 抓证据。

### Case A — 进入 History Tab 的基线开销

**复现步骤**

1. `killall Type4Me` 干净启动
2. 打开设置 → 切到「识别历史」tab
3. 不滚动，停留 30 秒

**测量**

- Activity Monitor 记录 30 秒末的 Type4Me 内存
- Console.app 搜索 `ForEach`（日志见 Case E）

**修复前预期**

- 内存：≥ 400 MB（1500 条 records 全部转成 `HistoryRecord` + 渲染顶端 50 条 + 各 textSelection 资源）
- 控件正常显示，第一屏不白屏（只有上方统计 + 顶部 50 条记录）

> 这一步是基线，不是 bug 主战场。重点是给后续 case 一个对比起点。

### Case B — 滚动到底，内存"持续上涨"

**复现步骤**

1. 接 Case A 状态
2. 把鼠标放到列表上，连续滚动到底（或反复滚动 30 秒）
3. 停止滚动后保持 1 分钟不动

**测量**

- 每 10 秒记录一次内存读数
- 记录 Activity Monitor 是否标红 "Not Responding"

**修复前预期**

| 时刻 | 内存（应当≥） | 状态 |
|---|---|---|
| 滚动开始 | 400 MB | 正常 |
| 滚动到底 | 700 MB | 卡顿，FPS 明显下降 |
| 停止后 30 秒 | 1.0 GB | 主线程偶发 Not Responding |
| 停止后 60 秒 | 1.1+ GB | Not Responding 持续，列表区可能白屏 |

匹配用户截图（图 1：1.06 GB，图 2：1.13 GB，间隔 ~10 秒涨 70 MB）。

### Case C — Not Responding + UI 卡顿

**复现步骤**

1. 接 Case B（滚动后内存已经上去）
2. 立刻点击侧栏切到「通用」tab，再切回「识别历史」
3. 在搜索框里快速打 5 个字符

**测量**

- 每个动作的"按下到屏幕响应"延迟，估秒数
- 是否触发 macOS 的「Force Quit」感知（窗口标题栏 spinner、点击不响应）

**修复前预期**

- 切换 tab 延迟 ≥ 1 秒；可能直接卡 3–5 秒
- 搜索框打字明显丢帧、字符延迟显示
- 图标栏出现旋转的 wait cursor

### Case D — 列表区白屏

**复现步骤**

1. 接 Case B
2. 用 Cmd+滚动 或 Home/End 键试图快速跳到顶部
3. 等 5 秒观察列表区

**测量**

- 截图记录白屏区域大小、持续时间

**修复前预期**

- 列表中段或底部出现长条空白（dateSection 占位但 records 没渲染出来）
- 持续时间 ≥ 3 秒，与用户图 3 描述一致

### Case E — ForEach Slow Path 直接证据 ⭐

这是判断 L1 是否真的命中的**金标准**。Apple 提供了官方诊断 launch argument。

**复现步骤**

1. 退出 Type4Me
2. 用诊断模式启动：
   ```bash
   /Applications/Type4Me.app/Contents/MacOS/Type4Me -LogForEachSlowPath YES &
   ```
3. 打开 Console.app，过滤进程 `Type4Me`，搜索 `ForEach` 或 `slow path`
4. 进入「识别历史」tab，滚动列表

**测量**

- Console.app 是否出现包含 `ForEach` + `slow path` 的日志条目
- 抓 5 行作证据贴在 PR 描述里

**修复前预期**

- 至少出现一条 SwiftUI runtime 警告，类似：
  ```
  ForEach<…> count … Use of non-constant view counts inside ForEach is a slow path
  ```

### Case F — 主线程 CPU 热点

**复现步骤**

1. 退出 Type4Me，用 Instruments 启动并选 Time Profiler 模板
2. attach 到 Type4Me，点录制
3. 进入「识别历史」tab，连续滚动 20 秒
4. 停止录制，按"Sample Count"排序看 main thread 的 heaviest stack

**测量**

- main thread 自顶向下，记录占比 ≥ 5% 的函数

**修复前预期**

main thread 高占比函数包含（不要求完全一致，能看到这个量级即可）：

- `Foundation.DateFormatter.init` / `_CFLocaleCreate*` (DayGroup.title)
- `Calendar.startOfDay(for:)` 或 `_CFCalendarComposeAbsoluteTime` (groupedRecords)
- `Dictionary._Variant.merge` / `Swift._ArrayBuffer` (groupedRecords 重建)
- `SwiftUI.AttributeGraph._evaluate` 占比异常高（slow path 全量 diff）

### Case G — 内存归属（哪些对象在涨）

**复现步骤**

1. Instruments → Allocations 模板 attach Type4Me
2. 标记 generation A → 进入历史 tab → 标记 generation B
3. 滚动 30 秒 → 标记 generation C
4. 静置 1 分钟 → 标记 generation D
5. 看 generation B → D 的 "Persistent" 增长

**修复前预期**

- 增长占比 top 类型可能含：
  - `NSTextView` / `NSConcreteTextStorage`（textSelection 累积）
  - `__NSArrayM`、`__NSDictionaryM`（groupedRecords 临时对象未尽快释放）
  - `_TtCs26_SwiftUIRendererHostNSView` 或类似 SwiftUI 内部 view backing
- 单 generation 增量 ≥ 50 MB

---

## 3. 验证修复：改完之后必须达标的测试 (After)

跑同样 7 个 case，对比下表。任何一项没达标就说明修得不彻底。

### 3.1 量化指标对比表

| Case | 指标 | 修复前 | 修复后目标 | 备注 |
|---|---|---|---|---|
| A | 进入 tab 30s 后内存 | ≥ 400 MB | ≤ 250 MB | textSelection 移除后下降幅度更大 |
| B | 滚到底 + 静置 1min 内存峰值 | ≥ 1.1 GB | ≤ 350 MB | **核心指标**，不达标 = 修了个寂寞 |
| B | 滚动期间是否 Not Responding | 是 | 否 | |
| C | tab 切换响应延迟 | ≥ 1s | < 200ms | |
| C | 搜索框打字丢帧 | 是 | 否 | |
| D | 列表白屏 | 是 (≥ 3s) | 否 | |
| E | Console `ForEach slow path` 日志 | 出现 | **不出现** | **L1 直接判定**，必须为零 |
| F | DateFormatter 主线程占比 | ≥ 5% | < 0.5% | DayGroup.title 改 cached |
| F | Calendar.startOfDay 占比 | ≥ 5% | < 0.5% | groupedRecords 改 @State 缓存 |
| G | 滚 30s + 静置 1min 内存净增 | ≥ 200 MB | ≤ 30 MB | 释放正常的话基本归零 |

### 3.2 行为类回归（不能因为改性能把功能改坏）

| 场景 | 预期 |
|---|---|
| 进入历史 tab → 看到统计 + 第一屏 50 条 | 一致 |
| 搜索某个关键字 → 列表过滤 | 一致 |
| 选「今天 / 昨天 / 本周 / 本月」过滤 | 一致 |
| 自定义日期范围过滤 | 一致 |
| 「日期分组标题」(今天/昨天/星期一/2026年4月20日) | 一致，文案没破 |
| 点 record 内的「复制」按钮 | 复制成功，按钮显示「已复制」1.5s 后还原 |
| 多个 record 连续点复制 | 每个按钮独立显示状态，**不会触发整列表重绘**（这是修复 L2 的副带收益） |
| 点「纠错」打开 sheet | 一致 |
| 点「删除」从数据库删除并从列表移除 | 一致 |
| 切到选择模式 → 多选 → 批量删除 | 一致 |
| 滚到底触发 loadMore | 加载下一页 50 条，没死循环 |
| 录入新记录后切回历史 tab | 列表自动刷新出现新记录 |
| 导出 CSV（全部 / 日期范围）| 一致 |

### 3.3 Edge Cases

| 场景 | 预期 |
|---|---|
| 0 条记录 | 显示 emptyState，不崩 |
| 1 条记录 | 显示 1 个 dateSection 1 条 record |
| 50 条全在今天 | 单 dateSection 50 条 record，不卡 |
| 5000 条 records（超量压测）| 滚动流畅 (≥ 50 FPS)，内存峰值 ≤ 600 MB |
| 切换语言 zh ↔ en | DayGroup.title 跟着切（如果用了 cached formatter，记得在语言切换时清缓存）|

---

## 4. 验证执行顺序建议

1. 先跑 **Case E**（slow path 日志）—— 5 分钟，结论二元，是判断 L1 修没修干净的最快测试
2. 再跑 **Case B**（内存峰值）—— 用户最痛的指标
3. 再跑 **Case F**（CPU 热点）—— 验证 L2 缓存是否生效
4. 再跑 **Case G**（内存归属）—— 验证 L3 textSelection 是否真的解掉
5. 最后跑 **3.2 行为回归** —— 确认没改坏功能

当时计划将每个 case 的截图和 Instruments trace 保存到 docs/screenshots/issue-144/；该产物目录未进入或已不保留在当前仓库中。

---

## 5. 退路与开关

如果 P2（移除 textSelection）测下来用户体感变差（少了文本选择能力），保留 textSelection 但加一个开关：

```swift
@AppStorage("tf_historyTextSelectable") private var historyTextSelectable = false
```

并在「关于」或「实验功能」里给个隐藏 toggle。默认 false，性能优先。

---

## 6. 跟踪

修复 PR 关联本测试方案。PR 描述贴：

- Case E 修复前后的 Console.app 截图（一张有 slow path 警告，一张干净）
- Case B 修复前后的 Activity Monitor 截图（峰值对比）
- Case F 修复前后的 Time Profiler heaviest stack 对比
