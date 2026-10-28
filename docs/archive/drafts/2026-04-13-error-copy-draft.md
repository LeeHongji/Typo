# Type4Me 错误文案统一规划

> **归档文档 · 草稿（2026-04-13）**：仅保留历史背景，不代表当前错误文案规范。当前文档入口见 `docs/README.md`。

> 原则: 用户不需要知道 HTTP 状态码、JSON 结构、系统错误类名。告诉他发生了什么、能做什么。

## 通用错误

| # | 场景 | 原始展示 | 草稿文案 (中) | 草稿文案 (英) | 哥的修改 |
|---|------|---------|-------------|-------------|---------|
| 1 | 网络不通 | `The network connection was lost` | 网络连接失败，请检查网络后重试 | Network error, please check your connection | |
| 2 | 服务器错误 (5xx) | `HTTP 500: {"error":"internal"}` | 服务器开小差了，请稍后重试 | Server error, please try again later | |
| 3 | 请求异常 (其他 4xx) | `HTTP 403: ...` | 请求失败，请稍后重试 | Request failed, please try again later | 服务器开小差了，请稍后重试 |
| 4 | 超时 | `The request timed out` | 请求超时，请检查网络后重试 | Request timed out, please check your connection | 服务器开小差了，请稍后重试 |

## 账户相关

| # | 场景 | 原始展示 | 草稿文案 (中) | 草稿文案 (英) | 哥的修改 |
|---|------|---------|-------------|-------------|---------|
| 5 | 验证码发送失败 | `error.localizedDescription` | 验证码发送失败，请稍后重试 | Failed to send code, please try again | |
| 6 | 验证码错误/过期 | `invalid or expired code` | 验证码错误或已过期，请重新获取 | Invalid or expired code, please request a new one | |
| 7 | 用户名或密码错误 | (已有文案，OK) | 用户名或密码错误 | Invalid username or password | |
| 8 | 用户名已被占用 | (已有文案，OK) | 用户名已被占用 | Username already exists | |
| 9 | 登录已过期 | (已有文案，OK) | 登录已过期，请重新登录 | Session expired, please log in again | |
| 10 | 设备冲突 | (已有文案，OK) | 账户已在其他设备登录 | Account logged in on another device | |
| 11 | 登录频率限制 | `too many failed attempts...` | 尝试次数过多，请稍后再试 | Too many attempts, please try later | |

## 功能相关

| # | 场景 | 原始展示 | 草稿文案 (中) | 草稿文案 (英) | 哥的修改 |
|---|------|---------|-------------|-------------|---------|
| 12 | LLM 代理失败 | `Server error (502)` | 文本处理服务暂时不可用 | Text processing service temporarily unavailable | |
| 13 | LLM 业务错误 (额度不足等) | 服务端原始 message | 额度已用完，请充值后继续使用 | Quota exhausted, please top up to continue | 额度已用完，请订阅后使用 |
| 14 | 账单加载失败 | `error.localizedDescription` | 账单加载失败 | Failed to load billing history | |
| 15 | ASR 变体生成失败 | `error.localizedDescription` | 生成失败，请重试 | Generation failed, please retry | |
| 16 | ASR 识别出错 (浮动条) | 透传 error description | 识别失败，请重试 | Recognition failed, please retry | |

## 备注

- 7-10 现有文案已经 OK，不用改
- 13 需要看服务端实际会返回哪些业务错误码，可能要拆成多条
- 所有文案用 `L("中文", "English")` 双语宏
