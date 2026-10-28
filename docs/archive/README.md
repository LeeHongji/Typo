# Type4Me 历史文档归档

> 文档状态：归档索引
> 最后整理：2026-08-11

本目录只用于追溯设计演进、历史审查、一次性测试和旧草稿。这里的内容不代表当前产品规范或代码状态；当前入口见 [`docs/README.md`](../README.md)。

## 1. 历史计划与设计

| 日期 | 文档 | 归档状态 |
|---:|---|---|
| 2026-04-16 | [History Date Filter Design](plans/2026-04-16-history-date-filter-design.md) | 已实施，保留 Issue #133 设计背景 |
| 2026-04-01 | [Native SenseVoice Design](plans/2026-04-01-native-sensevoice-design.md) | 已实施，保留本地 ASR 架构演进 |
| 2026-04-01 | [Native SenseVoice Implementation Plan](plans/2026-04-01-native-sensevoice-plan.md) | 已实施，任务清单不再生效 |
| 2026-03-29 | [Local LLM Integration Plan](plans/2026-03-29-local-llm-integration-plan.md) | 历史计划，实现路径已演进 |
| 2026-03-29 | [SenseVoice Python Service Design](plans/2026-03-29-sensevoice-python-service-design.md) | 已被原生 Swift 方案替代 |
| 2026-03-29 | [SenseVoice Python Service Plan](plans/2026-03-29-sensevoice-python-service-plan.md) | 已被原生 Swift 方案替代 |

## 2. 历史代码审查与开发报告

| 日期 | 文档 | 归档状态 |
|---:|---|---|
| 2026-08-08 | [多快捷键 Code Review](reviews/2026-08-08-multi-hotkey-code-review.md) | 对应当时分支快照 |
| 2026-08-08 | [多快捷键开发报告](reviews/2026-08-08-multi-hotkey-development-report.md) | 对应当时实现与测试快照 |
| 2026-08-08 | [设置窗口 UI Code Review 说明](reviews/2026-08-08-ui-redesign-code-review-notes.md) | 对应当时 UI 改造 |
| 2026-08-07 | [设置窗口 UI Code Review 报告](reviews/2026-08-07-ui-redesign-review-report.md) | 对应当时分支快照 |
| 2026-04-12 | [代码评估报告（HTML）](reviews/2026-04-12-code-review.html) | 对应当时代码快照 |
| 2026-03-30 | [Code Review](reviews/2026-03-30-code-review.md) | 对应当时代码快照 |

## 3. 历史实施报告

| 日期 | 文档 | 归档状态 |
|---:|---|---|
| 2026-04-03 | [社区 PR 合并与改造](reports/2026-04-03-community-pr-merge.md) | 记录 5 个社区 PR 的当时合并范围 |

## 4. 历史测试计划

| 日期 | 文档 | 归档状态 |
|---:|---|---|
| 2026-04-26 | [Issue #144 历史记录性能测试](test-plans/2026-04-26-issue-144-history-performance.md) | 仅适用于该 Issue |
| 2026-04-13 | [Issues 批量手动测试](test-plans/2026-04-13-issues-batch-manual-test-cases.md) | 仅适用于所列旧 Issues |
| 2026-04-13 | [v1.9.0 Release Test Cases](test-plans/2026-04-13-v1.9.0-release-test-cases.md) | 仅适用于 v1.9.0 |

## 5. 历史草稿

| 日期 | 文档 | 归档状态 |
|---:|---|---|
| 2026-04-13 | [错误文案统一规划](drafts/2026-04-13-error-copy-draft.md) | 未形成当前错误文案规范 |
| 2026-04-03 | [热词与映射词表 v2](drafts/2026-04-03-vocabulary-v2-draft.md) | 旧词表草稿，不代表当前内置词表 |

## 6. 历史视觉资产

- `assets/visual-explorations/`：未被当前 README 使用的 header 方案、旧截图和浮窗视觉稿；
- `assets/legacy-settings-screenshots/`：旧版设置页面截图；
- 当前 README 素材保留在 `docs/images/`，当前产品截图保留在 `docs/screenshots/`。

## 7. 归档规则

- 不在归档文档中继续追加当前需求；
- 只允许修复失效链接、明显排版问题和归档说明；
- 新实现需要引用历史决策时，链接到具体归档文件并注明日期；
- 旧方案被新方案替代时，在旧文档和本索引中同时注明；
- 不删除仍有追溯价值的历史材料；确需删除时由独立提交说明原因。
