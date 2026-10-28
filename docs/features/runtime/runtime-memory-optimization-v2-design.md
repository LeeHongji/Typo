# Type4Me 运行时内存优化二期（深入治理）开发设计文档

> 文档类型：专项开发设计 / 运行时优化设计
> 文档状态：当前有效（第一阶段与内存版 Flat Trie 已实现，Build 50 初步验证）
> 适用平台：macOS 14+ (Apple Silicon & Intel)
> 技术栈：Swift 6.2、C++20、URLSession（每连接独立 session，效果继续观测）/ Network.framework NWConnection（备选）、内存版 Flat Trie、SQLite3、SwiftUI
> 设计日期：2026-08-15
> 最后校验：2026-08-15
> 上游指南：`docs/guides/runtime-memory-optimization.md`
> 实现基线：当前工作树（Build 48，实测 footprint 115 MB，峰值 198 MB）
> 初步验证：Build 50 运行约 41 分钟并完成 33 次录音（30 次快速、3 次智能感知）后，空闲 footprint 37.4 MB、存活堆 16.7 MB；详见 5.1。

---

## 1. 背景与现状诊断

### 1.1 一期优化成果与残留问题

在近期的一期内存优化（提交 `dbc8d1f` 与 `36a65d5`）中，完成了以下改进：
- **UI 层**：设置窗口改为单标签按需挂载，Ask 面板延后按需创建；
- **LLM 层**：引入 `LLMClientCache` 统一复用客户端与 `URLSession`，配置失效时显式 `invalidate()`；
- **ASR 层**：Volcano 与 Soniox 改为回调驱动 receive，解绑长期 Swift async continuation，并在结算后强制 cancel。

然而，在持续运行实测中（以运行约 2 天、经历多次录音和智能感知触发的 `Type4Me Dev` 进程 PID 5126 为例），进程的物理内存占用（Physical Footprint）仍高达 **115 MB**（峰值 **198 MB**）。

### 1.2 运行时堆内存实测数据拆解

通过 `footprint`、`vmmap` 与 `heap -s` 工具对实际运行进程进行底层分析，数据分解如下：

```text
======================================================================
Type4Me [5126]: 64-bit    Footprint: 115 MB (16384 bytes per page)
======================================================================
  Category                  Dirty Memory    Region Count
  -----------------------   ------------    ------------
  MALLOC_SMALL                     89 MB              33
  MALLOC_LARGE                   6016 KB               1
  __DATA / __DATA_DIRTY          5916 KB            1889
  NetworkAgent (Network)         1626 KB             653
  SecCertificate (CFType)        1933 KB             927
  TOTAL DIRTY FOOTPRINT           115 MB
```

> **口径说明（重要，避免重复计数）**：SQLite 默认页面缓存走**堆分配**（`sqlite3MallocMalloc`），已计入上表的 `MALLOC_SMALL/MALLOC_LARGE`，**不是独立于 Footprint 之外的 27.5 MB**。因此下文对 SQLite 的 27.5 MB 是「`MALLOC` 内部归属于 SQLite pagecache 的子集」的估算值（经 `heap -s <pid> | grep -i sqlite`/`malloc_history` 抽样归因），而非在 115 MB 之外新增。上表分类相加不应超过 115 MB；各"归属源"是对 `MALLOC_*` 内部的进一步拆解，存在父子包含关系。

深入分析 `MALLOC_SMALL` 的 89 MB 堆内存分布：

| 节点类型 | 节点大小 | 实例数量 | 直接负载 | 归属源 |
|---|---|---|---|---|
| `non-object` | 16 Bytes | **314,908** | ~5.0 MB | CppJieba `TrieNode` 实例 |
| `non-object` | 32 Bytes | **250,884** | ~8.0 MB | CppJieba `unordered_map` 的 `__hash_node` |
| `non-object` | 48 / 64 / 80 B | **157,418** | ~8.8 MB | CppJieba 哈希桶、动态 vector、string 存储 |
| **CppJieba 直接负载小计** | 16 ~ 160 B | **> 720,000** | **~22 MB** | 上述三行之和 |
| **CppJieba 实际脏物理占用** | — | — | **~52 MB** | 直接负载 ~22 MB + 分配器碎片/页对齐放大（见下方说明） |
| `__NSURLSessionWebSocketTask` | 1024 B | **102** | ~104 KB | **Volcano/Soniox 共享 `URLSession`** 累积的废弃 WebSocket 任务（见问题二订正） |
| `URLProtocol` | 1024 B | **102** | ~104 KB | CFNetwork 协议栈上下文 |
| `std::__shared_ptr<NWIOConnection>` | 768 B | **102** | ~78 KB | CFNetwork 底层 Socket 连接状态 |
| `SecCertificate` | 2135 B | **927** | **~1.98 MB** | 废弃连接滞留的 TLS 证书缓存 |
| `NetworkAgentBackingClass` | 2590 B | **638** | **~1.66 MB** | 系统网络代理与链路状态上下文 |
| `SVGAttribute / CoreSVG` | 112 B / 32 B | **14,323** | **~1.3 MB** | 疑似 SwiftUI 窗口相关的 SF Symbols 矢量数据（归属待 `vmmap` 复核，见问题四） |

> **关于 22 MB → 52 MB 的差额**：三行小对象的**净负载**约 22 MB，但 72 万个 16B/32B 对象散落在数千个 16 KB 系统页上，叠加 malloc 分配器的 size-class 对齐与元数据开销，使**实际脏物理页**放大到约 52 MB。该 52 MB 为 `vmmap` 中归属 CppJieba 分配栈的脏页估算值；若评审需要精确数值，应以 `malloc_history <pid> -allBySize` 的分配栈归因为准。

---

## 2. 核心问题定位

### 问题一：CppJieba 节点指针型 Trie 与静态缓存导致 50+ MB 脏内存与严重堆碎片（P0 - 绝对大头）

> **前置事实（既有机制）**：`JiebaChineseWordSegmenter` **已实现 10 分钟空闲驱逐**（`scheduleIdleEviction()` → `t4m_jieba_destroy(handle)`，`idleTimeout` 默认 `.seconds(600)`）。因此 handle 承载的**指针型 Trie 在空闲后确实会被销毁**。真正无法回落的是下述 ② 静态缓存与 ③ 分配器碎片——它们不随 handle 释放而归还系统。本方案的价值在于**补齐既有驱逐路径的最后一环**（清理静态缓存）并从根上消除碎片。

1. **极其细碎的堆分配**：`dict.txt.small` 包含 **109,749** 行词条。开源 CppJieba 原生使用指针节点型字典树：
   ```cpp
   class TrieNode {
       typedef unordered_map<TrieKey, TrieNode*> NextMap;
       NextMap *next;
       const DictUnit *ptValue;
   };
   ```
   插入 11 万词条时，为每个字符动态 `new TrieNode` 并分配 `std::unordered_map`，在堆上产生了 **超过 70 万个细碎分配**（16B、32B）。
2. **`GetDictCache` 进程级持久缓存（handle 销毁也不释放）**：`DictTrie.hpp:265-278` 使用 `static std::unordered_map<std::string, DictCacheEntry>`，其 `node_infos`（11 万词条的 `vector<DictUnit>`）经 `std::shared_ptr` 缓存后**永久驻留进程**。即使空闲驱逐调用了 `t4m_jieba_destroy`，也**只销毁 handle 内的 Trie，无法触及这个 C++ 静态变量**——目前没有任何清理入口。这是"空闲后仍不完全回落"的首要原因。
3. **分配器碎片导致物理内存无法回落**：大量 16B/32B 对象散落在数千个系统分配页（16KB Page）上。即使 handle 释放了 Trie 结构，只要一个页内还残留 1 个活跃指针（如静态缓存持有的 `DictUnit`），整个 16KB 页就无法返还给操作系统内核。

### 问题二：Volcano/Soniox 共享 `URLSession` 对已 cancel 的 WebSocket Task 的 O(N) 累积滞留（P0 - 随使用递增）

> **重要订正（相对早期草稿）**：早期分析将 Deepgram/Baidu/Bailian/ElevenLabs/AssemblyAI 列为泄露源，经核对源码**该判断有误**。这 5 个客户端**每次连接均新建独立 `URLSession(configuration:delegate:delegateQueue:)`，并在 `stop()` 时调用 `session?.invalidateAndCancel()`**（例见 [DeepgramASRClient.swift](file:///Users/kchen/Projects/type4me/Type4Me/ASR/DeepgramASRClient.swift#L116-L152)），属于**正确的隔离销毁模式，不会 O(N) 累积**。真正的泄露源是使用共享 session 的 **Volcano 与 Soniox**。

1. [SpeechRecognizer.swift](file:///Users/kchen/Projects/type4me/Type4Me/ASR/SpeechRecognizer.swift#L23-L34) 定义了进程级 `ASRRequestOptions.sharedSession`；`resolvedSession` 在**非 bypassProxy 的常规路径**下返回该共享 session。
2. 仅 [VolcASRClient.swift](file:///Users/kchen/Projects/type4me/Type4Me/ASR/VolcASRClient.swift#L102-L152) 与 [SonioxASRClient.swift](file:///Users/kchen/Projects/type4me/Type4Me/ASR/SonioxASRClient.swift#L65-L113) 使用 `options.resolvedSession`。二者在 `disconnect()` 中因 `ownsSession == false`（未 bypass 时），**只做 `socket?.cancel()` 而不 invalidate 共享 session**（正确——共享 session 不能被 invalidate，否则后续录音全部失效）。
3. 但在 macOS CFNetwork 实现中，`URLSession` 会在内部字典与队列中**强引用所有由它发起的 task**（含已 cancel 的 `__NSURLSessionWebSocketTask`）。因此每完成 1 次 Volcano/Soniox 录音，共享 session 内部就永久多滞留 1 个 `__NSURLSessionWebSocketTask` + 1 个 `NWIOConnection` + 8~9 个 `SecCertificate`。**实测 102 个滞留 task 与默认使用 Volcano（中文场景）的行为吻合。**
4. 一期优化已将 Volc/Soniox 的 receive 改为回调驱动（解绑了长期 async continuation），但**并未解决共享 session 对 task 本身的强引用**——这是本次要根治的残留。
5. 已正确隔离的 5 个客户端唯一的次要气味是 async `task.receive()` 循环，但它随每连接的 `invalidateAndCancel()` 一并释放，**不构成 O(N) 泄露**，无需迁移改造，仅作对照参考。

### 问题三：SQLite 数据库缓存无上限约束（P1）

[HistoryStore.swift](file:///Users/kchen/Projects/type4me/Type4Me/Database/HistoryStore.swift) 与 [AskAnythingStore.swift](file:///Users/kchen/Projects/type4me/Type4Me/Database/AskAnythingStore.swift) 打开数据库后，未对 SQLite 的 Page Cache 设置上限（`PRAGMA cache_size`）。当历史记录或对话增多时，SQLite 默认申请了高达 **27.5 MB** 的页面缓存。

### 问题四：SwiftUI `Window` 声明的顶层预初始化开销（P2 - 待 `vmmap` 复核，低置信度）

[Type4MeApp.swift](file:///Users/kchen/Projects/type4me/Type4Me/Type4MeApp.swift#L18-L47) 中直接在 `App.body` 声明了 3 个 `Window`（`settings`、`setup`、`permission-guide`）。

> **置信度提示**：SwiftUI `Window` 场景的 content 闭包在窗口打开前**通常是惰性的**，未打开窗口一般不会构建其 `AttributeGraph`/`CoreSVG`。因此"预初始化即产生 5~8 MB"缺乏直接证据，上文堆表中的 `SVGAttribute/CoreSVG ~1.3 MB` 也**尚未确认归属于未打开的窗口**（也可能来自 MenuBarExtra 状态项、设置窗口已被打开过一次后的驻留、或系统 SF Symbols 缓存）。**本项在实施前必须先用 `vmmap`/`heap` 归因确认实际占用与来源，再决定是否投入改造**；若归因不成立则降级/移除该项。

---

## 3. 总体优化架构与设计方案

```text
┌──────────────────────────────────────────────────────────────────────────┐
│                             Type4Me App Process                          │
├──────────────────────────────────────────────────────────────────────────┤
│ 1. CppJieba 治理                  │ 2. ASR 网络层治理                      │
│ ┌───────────────────────────────┐ │ ┌──────────────────────────────────┐ │
│ │ 紧凑二进制 DAT (Double-Array)  │ │ │ 主方案：Volc/Soniox 改用每连接     │ │
│ │ • 0 动态节点 malloc (60万→0)  │ │ │   独立 session + invalidateAndCancel│ │
│ │ • mmap 映射文件 (Clean Memory)│ │ │ • 复用已验证模式，0 新框架/低风险  │ │
│ │ • 物理 Footprint: 52MB → <2MB │ │ │ 备选：NWConnection (可选储备)      │ │
│ └───────────────────────────────┘ │ └──────────────────────────────────┘ │
├───────────────────────────────────┼──────────────────────────────────────┤
│ 3. SQLite 数据库治理              │ 4. SwiftUI 窗口与资源治理             │
│ ┌───────────────────────────────┐ │ ┌──────────────────────────────────┐ │
│ │ • PRAGMA cache_size = -2000   │ │ │ • NSHostingController 延迟呈现    │ │
│ │ • 空闲 sqlite3_db_release_mem │ │ │ • 避免未打开窗口的 AttributeGraph  │ │
│ │ • 虚拟缓存: 27.5MB → 2MB      │ │ │ • 减少 CoreSVG / DisplayList 占用  │ │
│ └───────────────────────────────┘ │ └──────────────────────────────────┘ │
└──────────────────────────────────────────────────────────────────────────┘
```

---

## 4. 详细实施方案

### 方案一：CppJieba 字典与 Trie 改造

#### 设计目标：
将 72 万个动态细碎小对象归零，将 CppJieba 内存从 **52 MB 脏堆内存** 降低至 **<2 MB 只读映射内存（Clean Memory）**，且分词查询延迟降低 30% 以上。

#### 实现路径：
1. **替换为紧凑双数组 Trie（Double-Array Trie, DAT）或扁平数组 Trie**：
   - 将 `dict.txt.small`（11 万词）在构建期（或首次加载时）编译为二进制扁平文件 `dict.small.bin`。
   - 二进制结构由连续数组组成（`base[]`, `check[]`, `weight[]`），不需要任何动态指针节点。
   - 运行时直接使用 `mmap`（只读映射）加载。操作系统可根据内存压力自动将 clean page 换出，不计入进程的脏物理内存（Dirty Footprint）。
2. **用户扩展词典（Overlay）改为轻量局部哈希**：
   - 基础 11 万词全部由只读 DAT 承载；
   - 用户纠正与热词扩展（通常 < 1000 词）使用一个紧凑的 `std::vector<UserWord>` 或小容量哈希表承载，动态占用 < 100 KB。
3. **全局生命周期清理接口**：
   - 在 `CppJiebaBridge` 中增加 `t4m_jieba_purge_global_cache()`，用于清空 `DictTrie` 内的 `GetDictCache` 静态 `unordered_map`（既有空闲驱逐只销毁 handle，无法触及该静态变量，这是本接口要补齐的关键缺口）。
   - 当 `JiebaChineseWordSegmenter` 处于空闲（10 分钟无请求，复用现有 `scheduleIdleEviction`）或收到内存警告时，在 `unloadHandle()` 之后调用该接口，并对 DAT 文件 `munmap`。

> **集成复杂度提示（勿低估）**：cppjieba 的 `MPSegment` 依赖 `Trie::Find` 返回 `const DictUnit*`（含 `weight`/`tag`）构建 DAG 并做动态规划分词。改用 DAT 不能只做"字符串命中"，还必须：① 在扁平二进制中一并承载每个词的 value（weight/tag）；② 提供 common-prefix-search 以复现 DAG 的每个候选边；③ 保持与 HMM 未登录词回退、`QuerySegment` 全切分行为一致。方向正确、收益明确，但属于 C++ 分词内核改写，工作量应按"新增一套 DAT 分词后端 + 离线构建器 + 行为对齐测试"评估，而非简单替换数据结构。

> **Build 50 实现说明**：本轮先落地内存版 Flat Trie，以连续 `vector<CompactNode>` / `vector<CompactChild>` 替代基础词典的海量节点哈希表；用户词仍使用小型动态 Trie。尚未生成离线 DAT 文件，也未使用 `mmap`，因此“<2 MB clean mapping”仍是后续目标。空闲卸载后通过 `t4m_jieba_purge_global_cache()` 清除静态词典缓存，实测原先 6,016 KB 的常驻大分配已消失。

---

### 方案二：ASR WebSocket 网络层治理（主方案：复用已验证的每连接独立 session）

#### 设计目标：
隔离每次 ASR 连接的 session 生命周期，并验证能否消除 `__NSURLSessionWebSocketTask`、`NWIOConnection` 和 `SecCertificate` 随录音次数线性递增的问题。网络残留归零是验收目标，不是实施前提。

#### 主方案（低风险、零新框架、优先落地）：

代码库中 **Deepgram/Baidu/Bailian/ElevenLabs/AssemblyAI 已在使用“每连接独立 `URLSession` + `invalidateAndCancel()`”模式**。本轮让 Volcano/Soniox/StepFun 对齐同一生命周期模式：

1. 让 `VolcASRClient` 与 `SonioxASRClient` **不再使用 `options.resolvedSession`（共享 session）**，改为每次 `connect()` 时新建独立 `URLSession(configuration:)`；
2. 在 `disconnect()` 中**无条件** `session?.invalidateAndCancel()`（不再依赖 `ownsSession` 分支）；
3. 保留一期已完成的回调驱动 receive（避免 async continuation 滞留）。

> **Build 50 实测订正**：33 次完成录音后，堆中仍有 33 个 `__NSURLSessionWebSocketTask`、33 个 `URLProtocol` 和 33 个 `NWIOConnection`，虽然没有存活 TCP fd。说明 `invalidateAndCancel()` 完成了逻辑关闭，但没有让 CFNetwork task 外壳立即析构；“网络残留严格归零”的验收目标尚未达成。当前这些对象的直接负载较小，不能把本轮 footprint 下降归因于其消失。

#### 备选方案（可选技术储备）：迁移至 Network.framework (`NWConnection`)

若后续希望更精细地控制握手超时、TCP Keepalive，或彻底摆脱 CFNetwork 的会话级 task 管理表，可将传输层迁移至 `NWConnection(.webSocket)`。这是对全部 ASR 客户端的高风险大改造，本期仍只作为储备设计；是否投入取决于后续增长斜率和真实 footprint，而不是仅看对象计数。

- `NWConnection` 支持原生 WebSocket（`NWProtocolWebSocket.Options`），无 `URLSession` 的会话级任务表与持久证书持有；
- `connection.cancel()` + `connection = nil` 后，TLS 上下文、Socket fd、证书缓存、接收缓冲区会**立即完整析构**；
- 迁移复杂度需注意：`.receiveMessage` 收帧循环、各家鉴权 header 与 query 签名差异、握手错误映射，均需逐客户端适配，工作量不应低估。

##### `NWConnection` 参考实现（注意示例中的 header 设置修正）：

```swift
final actor NWWebSocketClient: Sendable {
    private var connection: NWConnection?
    private var receiveLoopActive = false

    func connect(to url: URL, headers: [String: String]) async throws {
        disconnect() // 确保清理旧连接

        let host = NWEndpoint.Host(url.host ?? "")
        let port = NWEndpoint.Port(integerLiteral: UInt16(url.port ?? (url.scheme == "wss" ? 443 : 80)))

        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.enableKeepalive = true

        let wsOptions = NWProtocolWebSocket.Options()
        // 修正：setAdditionalHeaders 是"整体设置"，在循环内反复调用会互相覆盖，
        //       只保留最后一个 header。必须先构建完整数组，再一次性设置。
        wsOptions.setAdditionalHeaders(headers.map { HTTPHeader(name: $0.key, value: $0.value) })

        let params = (url.scheme == "wss")
            ? NWParameters(tls: .init(), tcp: tcpOptions)
            : NWParameters(tls: nil, tcp: tcpOptions)
        params.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)

        let conn = NWConnection(host: host, port: port, using: params)
        self.connection = conn

        try await withCheckedThrowingContinuation { continuation in
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    continuation.resume()
                case .failed(let error):
                    continuation.resume(throwing: error)
                case .cancelled:
                    break
                default:
                    break
                }
            }
            conn.start(queue: .global(qos: .userInitiated))
        }

        startReceiveLoop() // 需实现基于 connection.receiveMessage 的收帧循环
    }

    func send(data: Data) async throws {
        guard let connection else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
        let context = NWConnection.ContentContext(identifier: "ws-binary", metadata: [metadata])
        try await withCheckedThrowingContinuation { continuation in
            connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }

    func disconnect() {
        guard let conn = connection else { return }
        connection = nil
        conn.stateUpdateHandler = nil
        conn.cancel() // 立即释放所有 TLS/Socket 资源，无 session 缓存
    }
}
```

#### 对已隔离客户端的处理：
Deepgram、Baidu、Bailian、ElevenLabs、AssemblyAI **已是正确的每连接独立 session + `invalidateAndCancel()` 模式，本期无需改造**；如未来统一迁移至 `NWConnection`（备选方案），再一并纳入即可。

---

### 方案三：SQLite 数据库连接与 Page Cache 约束

#### 设计目标：
将 SQLite 运行时虚拟/常驻缓存从 **27.5 MB** 压缩到 **≤ 3 MB**。

#### 治理措施：
在 `HistoryStore.swift` 与 `AskAnythingStore.swift` 的 `sqlite3_open` 成功后，统一执行以下 Pragma 初始化：

```swift
private func configureDatabasePragmas(db: OpaquePointer?) {
    // 限制单库页面缓存最大为 2MB（负值表示以 KB 为单位）
    sqlite3_exec(db, "PRAGMA cache_size = -2000;", nil, nil, nil)
    // 临时表与中间结果使用内存
    sqlite3_exec(db, "PRAGMA temp_store = MEMORY;", nil, nil, nil)
    // 禁止过大的 mmap 映射
    sqlite3_exec(db, "PRAGMA mmap_size = 2097152;", nil, nil, nil)
}
```

同时，在 `AppDelegate` 的空闲通知（如录音结束静置 60 秒或设置窗口关闭）中触发内存收缩：
```swift
func releaseDatabaseMemory() {
    Task {
        await historyStore.shrinkMemory()
        await askAnythingStore.shrinkMemory()
    }
}
// Store 内部调用: sqlite3_db_release_memory(db)
```

---

### 方案四：SwiftUI Window 按需创建与图标渲染开销优化

#### 设计目标：
消除未开启窗口时 CoreSVG 与 AttributeGraph 产生的 ~5 MB 静态占用。

#### 治理措施：
> **前置动作**：先用 `vmmap`/`heap` 归因确认 `SVGAttribute/CoreSVG` 与 `AttributeGraph` 的实际来源与占用；若确认与未打开的辅助窗口无关，则本方案降级或移除。以下措施在归因成立时执行。

1. **辅助窗口（Setup / Permissions）由 `Window` 场景转为轻量 `NSWindowController` / 按需呈现**：
   对于只在首次启动或授权异常时才使用的 `SetupWizardView` 与 `PermissionGuideView`，避免在 `App.body` 中通过 `Window(...)` 静态声明，改用 `NSHostingController` 在需要时弹出，关闭时彻底释放。
2. **设置页图标与矢量资源复用**：
   审查 `SettingsView` 中使用的高频 SF Symbols，避免在大列表中生成重复的冗余视图修饰符。

---

## 5. 验收指标与测试矩阵

### 5.1 Build 50 初步实测

在运行约 41 分钟、完成 33 次录音（30 次快速模式、3 次智能感知）并经历两轮 Jieba 空闲释放后：

| 指标 | Build 48 长时样本 | Build 50 初步样本 | 结论 |
|---|---:|---:|---|
| Physical Footprint | 99.1 MB（另一次设计基线为 115 MB） | 37.4 MB | 显著下降，仍需长时复测 |
| 存活堆 | 52.6 MB / 329,227 节点 | 16.7 MB / 89,284 节点 | Flat Trie 与空闲 purge 有效 |
| `MALLOC_SMALL` | 74 MB | 24 MB | 显著下降 |
| SQLite page cache | 约 20 MB 虚拟缓存 | 768 KB | 当前低于 3 MB 目标 |
| ASR WebSocket task | 随录音增长 | 33 次录音后残留 33 个 | 独立 session 未消除 O(N) 对象计数 |
| 传统泄漏 | 192 B | 80 B | 可忽略 |

该样本验证了当前空闲稳态收益，但运行时间远短于 Build 48 长时样本，不能据此宣称已经通过 24 小时或 1000 次录音验收。

### 5.2 核心内存指标目标

| 检查场景 | 当前实测基线 (Build 48) | 优化后目标 | 预期降幅 |
|---|---|---|:---:|
| **冷启动（未触发 Jieba、未开设置）** | 37.3 MB | **≤ 25 MB** | **-33%** |
| **首次触发中文智能感知（加载 Jieba）** | 115 MB（脏内存累积） | **≤ 35 MB**（Clean Mmap） | **-70%** |
| **长时间静置 / Jieba 空闲 10 分钟后** | 115 MB（残留不回落） | **≤ 28 MB**（完全回落） | **-75%** |
| **连续录音 100 次后（ASR 压力）** | Volcano/Soniox 共享 session 滞留 102 个 WebSocketTask | **目标：0 个滞留；Build 50 尚未达成** | 待后续方案 |
| **全标签切换并关闭设置窗口 20 轮** | ~65 MB | **≤ 32 MB** | **-50%** |
| **SQLite Page Cache 占用（MALLOC 内子集）** | ~27.5 MB | **≤ 3 MB** | **-89%** |

### 5.3 验证方法

执行标准测量脚本并结合 macOS 原生诊断：
```bash
# 1. 测量冷启动物理内存
bash scripts/measure-runtime-memory.sh <pid> cold /tmp/type4me-perf.csv

# 2. 测量 50 次录音后的堆对象，检查 WebSocketTask 数量与 footprint 增长斜率
heap <pid> | grep -E "WebSocket|NWIOConnection|SecCertificate"

# 3. 检查非对象堆分配节点总数（检查 16B/32B 小节点是否降至 <2万）
heap -s <pid> | head -n 30

# 4. 检查物理 footprint 与脏内存
footprint <pid>
```

---

## 6. 分阶段实施路线图

1. **第一阶段（快速收益，低风险）**：
   - 落地 SQLite Pragma 缓存限制（`-2000`）与 `sqlite3_db_release_memory`。
   - **已实现** Volcano/Soniox/StepFun 每连接独立 `URLSession` + teardown 无条件 `invalidateAndCancel()`；Build 50 证实连接关闭，但 CFNetwork task 外壳仍按录音次数保留，不能视为根治 O(N)。
   - 在 `CppJiebaBridge` 增加 `t4m_jieba_purge_global_cache()` 清理 `GetDictCache` 静态缓存，并在既有 10 分钟空闲驱逐（`unloadHandle`）之后调用，补齐"不完全回落"的缺口。
2. **第二阶段（彻底解决分词内存大头）**：
   - **已实现第一步**：内存版 Flat Trie（含 value/weight 与 common-prefix-search）替代基础词典节点哈希表。
   - **后续可选**：将词典离线编译为二进制 DAT 并接入只读 `mmap`，在现有实测收益不足时再投入。
3. **第三阶段（可选储备，非必选）**：
   - 先用 `vmmap` 复核 SwiftUI Window / CoreSVG 的实际归属，成立才改造辅助窗口为按需 `NSHostingController`。
   - 如有需要，再评估将 ASR 传输层整体迁移至 `NWConnection`（备选方案），彻底摆脱 CFNetwork 会话级 task 管理表。
