# History Date Filter Design

> **归档文档 · 已实施的历史设计（2026-04-16）**：保留用于追溯 Issue #133 的设计决策。当前文档入口见 `docs/README.md`。

Issue: #133

## Problem

4300+ records with no date filtering. Users can only text-search or scroll to find past records. No way to jump to a specific day or see daily stats.

## Solution: Dropdown Menu Date Filter (Approach A)

### UI: Toolbar Menu Button

Insert a `Menu` button between search bar and "Select" button:

```
[🔍 搜索记录...    ] [📅 全部 ▾] [选择] [导出]
```

Menu items:
- 全部 (default, checkmarked)
- 今天
- 昨天
- 本周
- 本月
- Divider
- 自定义范围... (opens popover with two DatePickers + confirm)

Button states:
- Default ("全部"): standard style, matches Select/Export
- Filter active: text changes to label ("今天" or "4/15-16"), tinted `settingsNavActive`

"自定义范围" opens a standalone popover (reuses export date picker pattern, not nested in menu).

### Per-Day Section Grouping

Replace the 4-bucket DateGroup (today/yesterday/thisWeek/earlier) with actual calendar-day grouping.

Section header format: `{日期} · {条数}条 · {时长}`

Header naming:
- Today: "今天"
- Yesterday: "昨天"
- This week: "周三" etc.
- Older: "4月14日 (周一)"

Mini stats (count + duration) computed from loaded records. Top stats bar uses DB aggregate for accurate totals.

### Data Model

```swift
enum DateFilter: Equatable {
    case all
    case today
    case yesterday
    case thisWeek
    case thisMonth
    case custom(from: Date, to: Date)

    var dateRange: (start: Date, end: Date)? { ... }
}
```

New state in HistoryTab: `@State private var dateFilter: DateFilter = .all`

### Database

Extend HistoryStore with date-range-aware queries:

```swift
func fetchFirst(limit: Int, from: Date?, to: Date?) -> [HistoryRecord]
func fetchPage(limit: Int, before cursor: String, from: Date?, to: Date?) -> [HistoryRecord]
func getStatistics(from: Date?, to: Date?) -> Statistics
```

All queries use existing `idx_history_created_at` index. No new indices needed.

### Data Flow

1. User picks menu item -> `dateFilter` changes
2. `onChange(of: dateFilter)` -> `loadRecords()` with date range
3. `loadStatistics()` with same date range
4. `records` replaced, list re-renders with per-day grouping
5. Scroll to bottom -> `loadMore()` with date range + cursor

### Out of Scope

- Calendar grid view: panel too narrow, overkill for a voice tool
- Per-day DB aggregate in section headers: loaded-data computation is good enough
- Week/month dimension toggle: date range picker covers this
