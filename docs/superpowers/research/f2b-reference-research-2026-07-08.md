# F2b Reference Research Report — 2026-07-08

> Source: 5 个 subagent 并行调研（swarm 模式），覆盖 tokenmeter / codeburn / tokscale / toll / ccusage
> Goal: 提取 F2b "API 价 vs 订阅价" 实施的通用设计模式 + 写 F2b v1 task list

## 1. 5 个 Reference 项目核心定位

| Reference | Language | Stars | Source 数 | Token King 借鉴重点 |
|---|---|---|---|---|
| **tokenmeter** | Go | 24⭐ | 17 | 完整架构 (UsageEntry + SQLite + source_id 去重 + LiteLLM pricing + 24h cache) |
| **codeburn** | TypeScript | 8.4K⭐ | 33 | Kimi 3-tier model ladder · Codex `prevCumulativeTotal=null` sentinel · Cursor `dedupKey` 无 token · safePerTokenRate clamp |
| **tokscale** | Rust | 4K⭐ | 37 | ClientId 枚举 + UnifiedMessage + PathRoot + SourceFingerprint + bincode cache |
| **toll** | Rust crate | — | 1 (Kimi only) | 极简实现：hardcode model "kimi-for-coding" + 全量 scan (不适合 menu bar) |
| **ccusage** | Node/TypeScript | — | Kimi detail | 完整 Kimi: subagent 路径 + reasoning 估算 + K2.6 cutoff + 3 schema 验证器 |

## 2. 跨 5 reference 共识的 7 个核心设计模式

### 2.1 UsageEntry 统一类型 (tokenmeter + tokscale + codeburn 一致)

```swift
struct TokenEvent: Codable, Hashable {
    let source: String           // "opencode", "claude_code", "codex", "kimi", ...
    let sourceId: String         // 唯一 dedup key
    let modelId: String          // 标准化后 model name
    let providerId: String       // "anthropic" / "openai" / "moonshot" / ...
    let sessionId: String        // 来自路径或 in-file
    let workspaceKey: String?    // 项目归属
    let timestamp: Date
    let tokens: TokenBreakdown   // 5 字段独立
    let cost: Decimal?           // 自报 cost vs 估算
    let costSource: CostSource   // .unknown | .providerReported | .estimated
    let agent: String?           // subagent 名
    let isFallbackModel: Bool
}

struct TokenBreakdown: Codable, Hashable {
    var input: Int = 0
    var output: Int = 0
    var cacheRead: Int = 0
    var cacheWrite: Int = 0
    var reasoning: Int = 0
}
```

### 2.2 source_id 三维去重双层 (tokenmeter + codeburn 一致)

```swift
// adapter 层 in-memory
var seenKeys: Set<String> = []

// 生成 dedupKey（不包含 token 数值，防 streaming in-place 更新）
func makeDedupKey(source: String, sessionId: String, messageId: String?, streamId: String) -> String {
    "\(source):\(sessionId):\(streamId):\(messageId ?? "nolimit")"
}

// storage 层（如果用 SQLite）
// UNIQUE INDEX idx_token_usage_source ON (source, session_id, source_id) WHERE source_id != ''
```

**关键纪律**：Cursor streaming 期间会 in-place 改 bubble 的 token 数值 — 如果 dedupKey 包含 token 数，同一会话会被计两次。必须用纯 key（不含 token）。

### 2.3 Pricing 层 (tokenmeter LiteLLM embed + codeburn 4 层 fallback + tokscale 5 级)

```
Priority:
1. User override  (config.json / CLI flag)
2. Live LiteLLM   (24h cache, ~80+ models)
3. Bundled snapshot (built-in embed，offline 兜底)
4. Builtin overrides (Cursor composer / Kimi k2.6 切点等)
5. Fuzzy match (case-insensitive, last resort)
```

`safePerTokenRate` clamp: `if (n > 1) return 1` 防 LiteLLM JSON 污染。

### 2.4 apply_total_token_fallback (tokenmeter + codeburn 统一规则)

```swift
// 当 4 个分桶 (input/output/cacheRead/cacheCreate) 都为 0 但 total > 0 时
// 把 total 折进 output_tokens，避免静默丢行
func applyTotalTokenFallback(_ event: inout TokenEvent) {
    if event.tokens.input == 0 && event.tokens.output == 0 &&
       event.tokens.cacheRead == 0 && event.tokens.cacheWrite == 0 {
        if event.tokens.reasoning == 0 {
            event.tokens.output = event.tokens.total
        }
    }
}
```

### 2.5 Env-var override + 默认路径 (5 reference 一致)

```swift
struct PathRoot {
    let homeRelative: String      // "~/.claude/projects"
    let envVar: String?           // "KIMI_DATA_DIR" (comma-separated multi)
    let xdgData: Bool             // respect $XDG_DATA_HOME
}

// 每个 source 都有 XXX_DATA_DIR env override（comma-separated, dedup）
```

`(nil, nil)` "user does not have X installed" 约定：env 没设 + 默认 dir 不存在 → 安静返回 (nil, nil)，不让外层报错。

### 2.6 byte offset 增量 + 文件截断重置为 0 (tokenmeter claude/codex watcher)

```swift
var seenOffsets: [URL: UInt64] = [:]

func watchFile(_ url: URL) {
    let currentSize = getFileSize(url)
    let lastOffset = seenOffsets[url, default: 0]
    if currentSize < lastOffset {
        // truncate / rotation — reset
        seenOffsets[url] = 0
    }
    let start = seenOffsets[url] ?? 0
    // read from start to currentSize
    seenOffsets[url] = currentSize
}
```

### 2.7 损坏 JSONL 行跳过 (5 reference 都做)

```swift
for try? line in jsonlLines(url) {
    guard let obj = try? JSONSerialization.jsonObject(with: line.data(using: .utf8)!) else {
        continue   // 损坏行跳过，绝不 panic 整 run
    }
    // parse obj...
}
```

## 3. 4 个真 token 工具的关键 schema（5 reference 验证一致）

### 3.1 OpenCode (tokenmeter + tokscale + codeburn)

```sql
-- SQLite table (OpenCode 1.2+)
SELECT json_extract(data, '$.tokens.input')      AS tokens_input,
       json_extract(data, '$.tokens.output')     AS tokens_output,
       json_extract(data, '$.tokens.reasoning')  AS tokens_reasoning,
       json_extract(data, '$.tokens.cache.read') AS tokens_cache_read,
       json_extract(data, '$.tokens.cache.write') AS tokens_cache_write,
       json_extract(data, '$.cost')              AS cost,
       json_extract(data, '$.model.providerID') AS provider_id,
       json_extract(data, '$.model.modelID')    AS model_id
FROM message
WHERE role = 'assistant'
  AND json_extract(data, '$.tokens') IS NOT NULL
```

**Fallback chain** (codeburn 三层):
1. `message.data.parts` (buildAssistantCall) → `modelID + providerID`
2. `session` 表 `model_id` 字段
3. drop row (model 缺失)

### 3.2 Claude Code (tokenmeter + codeburn + tokscale + ccusage)

```json
{"type":"assistant",
 "message":{"id":"msg_xxx","model":"claude-sonnet-4-5","role":"assistant",
            "content":[...],
            "usage":{
              "input_tokens":1000,
              "output_tokens":500,
              "cache_creation_input_tokens":200,
              "cache_read_input_tokens":300}}}
```

**Dedup 关键** (ccusage):
- 同 `messageId:requestId` 多次出现 → **per-field max**（input/output/cache 独立比较，保留更大的）
- 同一 messageId 多次 streaming 时，token 是渐进补充的，不能用 total 当 dedup key

**5m/1h cache write 分段** (codeburn):
```typescript
// Claude 1h cache write 比 5m 贵 1.6x
const cacheWriteMultiplier = cacheType === '1h' ? 1.6 : 1.0
const cost = cacheWriteTokens / 1e6 * baseInputRate * cacheWriteMultiplier
```

### 3.3 Codex (tokenmeter + tokscale + codeburn + ccusage)

```json
{"type":"event_msg",
 "payload":{"type":"token_count",
           "info":{
             "total_token_usage":{"input_tokens":1000,"output_tokens":500,
                                  "cached_input_tokens":300,"reasoning_output_tokens":100,
                                  "total_tokens":1900},
             "last_token_usage":{"input_tokens":200,"output_tokens":50,
                                 "cached_input_tokens":100,"reasoning_output_tokens":20,
                                 "total_tokens":370}}}}
```

**5 字段**（之前我漏算了 `reasoning_output_tokens`）:
- `input_tokens` (non-cached) = `total - cached`
- `cached_input_tokens` (cache hit)
- `output_tokens`
- `reasoning_output_tokens` (reasoning model)
- `total_tokens` (本行累计)

**`prevCumulativeTotal = null` sentinel** (codeburn 防 bug):
```typescript
// 不能用 0 当初值，否则首条 cumulativeTotal=0 会被当重复丢
let prevCumulativeTotal: number | null = null
```

**Fork replay** (Codex child 子 agent 重放父 history):
- 用 UUID v7 ms 时间戳 + `task_started` 标志判断是不是 child 自己的 turn
- 5s cutoff: forked session 在 fork 后 5s 内的 replay token 跳过

**OpenAI 语义 → Anthropic 语义 normalization** (codeburn):
```typescript
// OpenAI includes cached in input_tokens; Anthropic does not
const uncachedInputTokens = Math.max(0, inputTokens - cachedInputTokens)
```

**Model 字段位置**: `payload.turn_context.model` 或 `payload.session_meta.model_provider`，fallback `"gpt-5"`

### 3.4 Kimi CLI + Kimi Code (codeburn + ccusage + toll + tokenmeter)

**两套 schema** (ccusage PR #1362):

**老 kimi-cli** `~/.kimi/sessions/<group>/<session>/wire.jsonl`:
```json
{"timestamp":..., "message":{"type":"StatusUpdate",
  "payload":{"token_usage":{"input_other":2306,"output":420,
                            "input_cache_read":5120,"input_cache_creation":0},
             "message_id":"msg-xxx",
             "context_tokens":7426,
             "max_context_tokens":262144}}}
```

**新 kimi-code** `~/.kimi-code/sessions/<ws>/<session>/agents/<agent>/wire.jsonl` (5 components):
```json
{"time":...ms, "model":"kimi-code/kimi-for-coding",
 "usage":{"inputOther":2306,"output":420,"inputCacheRead":5120,"inputCacheCreation":0},
 "usageScope":"turn"}
```

**Model 字段缺失**（5 reference 共识）— 3-tier fallback (codeburn):
```
1. KIMI_MODEL_NAME env
2. ~/.kimi/config.toml 的 default_model (parse TOML)
3. "kimi-auto" 兜底
```

**K2.6 cutoff** (ccusage PR #840): 时间戳 `2026-04-20T15:28:10.072Z`（K2.6 发布日）之前 → K2.5 价，之后 → K2.6 价。

**Subagent 路径** (ccusage PR #840):
- `sessions/<ws>/<session>/subagents/<task-id>/wire.jsonl`
- 路径深度 5 = parent + 1 subagent；深度 7 = parent + 2 subagents (偶数层)
- `dedupeKey = "<session>:<streamId>:<messageId>"` 防止跨 stream 双计

**Reasoning 估算** (ccusage PR #840): `Math.ceil(text.length / 4)` chars/token 启发式 + `Math.min(reasoning, output)` clamp

**Aliases** (codeburn):
```
"kimi-auto" / "kimi-code" / "kimi-for-coding" → 定价 alias 到 kimi-k2-thinking
（防 managed sessions 显示 $0）
```

## 4. 5 reference 共识的 F2b v1 设计决策

### 4.1 F2b v1 应该做的 (5 reference 一致)

| 项 | 实现 | 来源 |
|---|---|---|
| UsageEntry 统一类型 | `TokenEvent` struct | 5 reference |
| Env-var override | `KIMI_DATA_DIR` / `OPENCODE_DATA_DIR` 等 | 5 reference |
| byte offset 增量 | `seenOffsets[path]` + truncate reset | tokenmeter |
| JSONL 损坏行跳过 | `try?` + continue | 5 reference |
| Dedup key 不含 token | `"\(source):\(session):\(stream):\(msgId)"` | codeburn Cursor |
| 5m/1h cache write 分段 | Claude model | codeburn |
| Kimi K2.6 cutoff | 时间戳切价 | ccusage |
| Kimi model 3-tier fallback | env → config → kimi-auto | codeburn |
| Codex `prevCumulativeTotal = null` sentinel | 防首条 0 丢 | codeburn |
| Codex OpenAI→Anthropic normalization | uncached = max(input - cached, 0) | codeburn |
| OpenCode 三层 model fallback | message.data → session.model → drop | codeburn |
| apply_total_token_fallback | 4 分桶 0 但 total > 0 时折 output | tokenmeter |
| safePerTokenRate clamp | `if n > 1 → 1` | codeburn |
| Swift dict-based parse (扛字段演进) | `[String: Any]?` + 探测路径 | toll |

### 4.2 F2b v1 不应该做的 (单 macOS 用户 menu bar 过重)

| 项 | 跳过原因 | Reference |
|---|---|---|
| 37 source 全支持 | F2b v1 只 5 真 + 2 降级 | tokscale |
| TUI dashboard | menu bar 不需要 | tokenmeter / tokscale |
| 8 个 Claude hooks 实时事件总线 | passive JSONL 够 | tokenmeter |
| Tool call 详情 / TUI message 回放 | 不在 F2b scope | tokenmeter |
| Web Dashboard + Budget + Webhook | 单用户不需要 | tokenmeter |
| Cross-config-dir 多目录 merge | v1 单 $HOME 够 | codeburn |
| Cursor agentKv blob 解析 | 只 bubbles 够 | codeburn |
| Warp / Zed / Forge 等 SQLite | v2 再评估 | tokscale |
| Daily aggregate cache | 实时 compute 够 | tokenmeter |
| bincode cache | Codable + JSON 易调试 | tokscale |
| rayon parallel 全核扫 | menu bar 启动敏感 | tokscale |

## 5. F2b v1 Task List（subagent-driven，估 3-5 天）

### Phase 1: 数据层 (3 task)

- [ ] **Task 1**: 实现 `TokenEvent` + `TokenBreakdown` struct + `CostSource` enum（Helpers/TokenEvent.swift）
- [ ] **Task 2**: 实现 `PricingTable` 集成（已有 PricingTable v2.12.0）+ `safePerTokenRate` clamp + `applyTotalTokenFallback`（Helpers/PricingEngine.swift）
- [ ] **Task 3**: 实现 5 真 token 工具的 TokenExtractor + e2e 单元测试（OpenCode SQLite / Claude Code jsonl / Codex rollout / 老 kimi-cli context / 新 kimi-code wire）

### Phase 2: 协调层 (2 task)

- [ ] **Task 4**: 实现 `TokenUsageStore` (actor) — source_id 三维去重 + SQLite UNIQUE INDEX + 增量 watch + 损坏行跳过
- [ ] **Task 5**: 实现 2 降级 provider adapter（Z.AI / NanoGpt 调 provider API）

### Phase 3: UI 层 (2 task)

- [ ] **Task 6**: 实现顶部 header "API 价 vs 订阅价" 新行（基于 StatusBarController:2011）+ 单 provider 详情新增 row
- [ ] **Task 7**: 实现 e2e driver test (per 项目 "UI bug 必须 e2e" 规则) — Xcode UI test 跑 build + screenshot 验证

### Phase 4: ship (1 task)

- [ ] **Task 8**: CLAUDE.md signal + version bump v2.12.0 → v2.13.0 + push

**每个 task 必须 subagent-driven** — main session 只做编排 + 5-question self-check review。

## 6. F2b v1 不立即做的事

- F2c 跨 provider 汇总（依赖 F2b 落地后单独 spec）
- 11 个其他 source（Cursor / Goose / Hermes / Kilo / Amp / 等）— v2 评估
- 高级聚合（TUI / Web / Budget alerts）— v3
- LiteLLM 24h cache 自动更新（v1 用 bundled snapshot + lazy fetch）

## 7. Gaps（subagent 报告里的未知）

| Gap | 影响 | 决策 |
|---|---|---|
| ccusage PR #840 未合并到 ccusage/ccusage@main | Kimi 实现参考可能 stale | Token King 用自己的实现，参考 azidancorp PR #840 |
| kimi-agent-rs Rust 源码未读 | 新 kimi-code Rust 行为可能跟 Python kimi-cli 不同 | F2b 实战时实测 wire.jsonl sample |
| Codex 0.128+ base_instructions 嵌入 session_meta | 可能 20-27KB，stream read cap 需调 | codeburn 1MB cap 兜底 |
| OpenCode 父子 session 是否分别显示 | CodeBurn 累到根，Token King 是否要分开 | F2b v1 累到根（简单），v2 分开 |
| Kimi model 前缀变化（kimi-code/xxx vs kimi-for-coding） | pricing 需 strip | codeburn 已处理 |

## 8. 关键文件位置

- `Helpers/PricingTable.swift` (F2a 落地，6 真 token + 2 降级 rates)
- `Helpers/PricingTableTests.swift` (F2a 8 tests)
- `App/StatusBarController.swift:2011` — 顶部 header "额度状态"
- `App/StatusBarController.swift:4390` — `dailyTotals` 模式参考
- `Helpers/ProviderMenuBuilder.swift:758` — tokenUsage % 单 provider 详情渲染
- `docs/superpowers/specs/2026-07-07-f2a-pay-as-you-go-pricing-table-design.md` — F2a 设计
- `docs/handoffs/2026-07-07-b44-session-handoff.md` — 上一 session 上下文
- `docs/handoffs/2026-07-08-f2b-session-handoff-2.md` — F2b 数据基础 verified

## 9. 下一步

F2b v1 task list 已写好（8 个 task，3-5 天，subagent-driven）。

**决策点**：
- 进 F2b spec 写 + plan 写 + implementation dispatch？
- 还是先 commit 这份 reference research report（当前未 commit）？
- 还是先开其他需求（F1 / F3 / F4）？