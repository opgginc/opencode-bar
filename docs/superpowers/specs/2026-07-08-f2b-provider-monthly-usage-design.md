# F2b — Provider Monthly Usage & Pay-as-you-go Cost

> Status: design 已获 user 4 问拍板 (2026-07-08)。brainstorming skill 第 6 步：写 spec。
> 关联：F2a spec `2026-07-07-f2a-pay-as-you-go-pricing-table-design.md` (已落地 v2.12.0) | handoff `2026-07-08-f2b-session-handoff-2.md` (数据基础 verified) | reference research `2026-07-08-f2b-reference-research.md` (5 reference 调研)

## 1. 背景 / 动机

**产品形态**（user 重新给定）：macOS 菜单栏应用 → 最终 macOS 桌面小部件。F2b 是菜单栏 MVP 阶段，桌面小部件留 v2。

**用户需求**（user 原话 + 2026-07-08 重述）：

1. **需求 1**: 每个 provider，统计当月用了多少总 token（如果可能，根据刷新时间算）
2. **需求 2**: 每个 provider，统计当月订阅的使用量，转换成模型 API 价格，花了多少钱
3. **产品定位**: provider 是主视角，工具只是 provider 接入的载体

**关键 correction**（之前 4-问 brainstorm 错了）：之前把"工具"（OpenCode/Claude Code/Codex 等 CLI）当 provider 处理。**实际是 provider（Kimi/Claude/Codex/Z.AI/NanoGpt）是主视角**，工具是数据源。F2a 阶段已落地 6 真 token 工具 + 2 降级 provider 的"按量单价表"（F2a PricingTable）；F2b 解决"按 provider 聚合月度用量 × 单价 = 月度折算价"。

**与 F2a 关系**：F2a 是"按量单价表"基础设施（每个 provider × 代表 model 一个 PayAsYouGoRate in RMB）。F2b 是"月度用量聚合 + 折算价计算"应用层（读 5 真 token 工具 + 2 降级 provider API，month-to-date 累计 × F2a 单价 = 月度折算价）。F2b 不动 PricingTable，只读它。

## 2. 设计决策记录（brainstorm 4 问）

| # | 决策点 | 选择 | 备选 |
|---|---|---|---|
| 1 | **Provider 归一化** | model 字段为主 + providerID 辅助 | tool 静态映射表 / 跨 tool 同 model + dedup |
| 2 | **时间窗** | Calendar month (本月 1 号到今天) | Rolling 30 天 / Calendar + 月历史 |
| 3 | **持久化** | SQLite (复用 OpenCode DB 模式) | UserDefaults 轻量 / 纯 in-memory 启动重算 |
| 4 | **Refresh 策略** | 30s tick 增量 | FSEvents file watcher / on-demand |

## 3. 架构

```
[macOS App - Menu Bar v1]
│
├── Layer 1: TokenExtractor (7 个工具适配器)
│   ├── OpenCodeExtractor  (SQLite opencode.db, message.data JSON, 5 token + model)
│   ├── ClaudeCodeExtractor (jsonl, 4 token + message.model)
│   ├── CodexExtractor    (rollout jsonl, 5 token + turn_context.model)
│   ├── KimiCLILegacyExtractor (context.jsonl, _usage.token_count)
│   ├── KimiCodeExtractor (wire.jsonl, event.usage camelCase 4 字段)
│   ├── ZAIExtractor      (provider API, 降级, 调 /usages endpoint)
│   └── NanoGPTExtractor  (provider API, 降级, 调 usage endpoint)
│
├── Layer 2: Provider Normalization
│   ├── 输入: TokenEvent { source, model, providerID, tokens(5), ts, sessionId }
│   ├── 规则 (model 字段为主):
│   │   ├── "kimi-*" / "k2p*"     → Provider.KIMI
│   │   ├── "claude-*"            → Provider.CLAUDE
│   │   ├── "gpt-*" / "o3-*" / "o4-*"  → Provider.CODEX (OpenAI family)
│   │   ├── "glm-*"               → Provider.ZAI
│   │   └── 其他 + providerID 辅助: "kimi" / "moonshot" → .KIMI, "anthropic" → .CLAUDE,
│   │                                  "openai" → .CODEX, "z-ai" / "zai" → .ZAI, 兜底 → .NANO_GPT
│   └── 输出: TokenEvent { provider, model, tokens, ts, sessionId, source, sourceId }
│
├── Layer 3: Store (SQLite, 30s tick 增量)
│   ├── table: token_events (raw, 跨 tool 归一化后, source_id UNIQUE)
│   ├── table: month_aggregates (per provider × model × year_month, 物化)
│   ├── table: model_pricing (F2a PricingTable 缓存, fetched_at)
│   ├── 30s tick actor: 全 tool 增量扫 → 算 sourceId → INSERT OR IGNORE
│   └── query: SELECT * FROM month_aggregates WHERE year_month = ?
│
├── Layer 4: Pricing Engine
│   ├── 输入: month_aggregates (provider, model, 5 token fields)
│   ├── 公式: cost = (input × inputRate + output × outputRate + cacheRead × cacheReadRate) / 1e6
│   ├── rate 来源: F2a PricingTable (PayAsYouGoRate.input/output/cache)
│   └── cacheWrite 不计费 (Anthropic prompt cache 写免费, OpenAI cache write 0.5x input 价)
│       -- 5 reference 共识: cacheWrite 通常不计费
│
├── Layer 5: UI
│   ├── Menu Bar: 顶层 "本月 API 折算 ¥XXX" + provider 列表 (需求 1+2)
│   ├── Per-Provider 详情: monthly breakdown by model
│   └── (v2) Desktop widget: 同样数据不同渲染
│
└── Layer 6: Error Handling
    ├── 损坏 JSONL 行跳过 (try? + continue, 5 reference 共识)
    ├── 数据源缺失 (env/路径) 静默返回 (nil, nil) — user 不知道
    ├── PricingTable 缺失 → cost = NULL + UI 标 "未知"
    ├── Schema 版本不匹配 → SQLite 加 schema_version + 不匹配整库 invalid
    └── Provider 归一化失败 → 默认 .NANO_GPT (兜底) + 日志记录
```

## 4. 数据形态

### 4.1 TokenEvent (跨 tool 归一化后)

```swift
struct TokenEvent: Codable, Hashable {
    let provider: Provider           // 归一化后: kimi/claude/codex/zai/nanoGpt
    let model: String                // 原始 model 名 (e.g. "kimi-for-coding")
    let source: TokenSource          // 数据源 (opencode/claude_code/...)
    let sessionId: String
    let timestamp: Date
    let tokens: TokenBreakdown
    let sourceId: String             // 去重 key: "<source>:<session>:<stream>:<msgId>"
}

enum Provider: String, Codable, CaseIterable {
    case kimi, claude, codex, zai, nanoGpt
}

enum TokenSource: String, Codable, CaseIterable {
    case opencode, claudeCode, codexCli
    case kimiCli, kimiCode
    case zaiApi, nanoGptApi
}

struct TokenBreakdown: Codable, Hashable {
    var input: Int = 0
    var output: Int = 0
    var cacheRead: Int = 0
    var cacheWrite: Int = 0
    var reasoning: Int = 0
}
```

### 4.2 SQLite Schema

```sql
-- Raw events (跨 tool 归一化后)
CREATE TABLE token_events (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  provider TEXT NOT NULL,           -- 'kimi' | 'claude' | 'codex' | 'zai' | 'nanoGpt'
  model TEXT NOT NULL,
  source TEXT NOT NULL,              -- 'opencode' | 'claudeCode' | 'codexCli' | 'kimiCli' | 'kimiCode' | 'zaiApi' | 'nanoGptApi'
  session_id TEXT NOT NULL,
  ts_ms INTEGER NOT NULL,            -- 毫秒 unix timestamp
  input INTEGER DEFAULT 0,
  output INTEGER DEFAULT 0,
  cache_read INTEGER DEFAULT 0,
  cache_write INTEGER DEFAULT 0,
  reasoning INTEGER DEFAULT 0,
  cost_usd REAL,                      -- NULL = PricingTable 没匹配
  source_id TEXT UNIQUE NOT NULL,     -- dedup key, 来源
  inserted_at INTEGER DEFAULT (strftime('%s','now'))
);

CREATE INDEX idx_token_events_provider_ts ON token_events(provider, ts_ms);
CREATE INDEX idx_token_events_session ON token_events(session_id);
CREATE INDEX idx_token_events_year_month ON token_events(strftime('%Y-%m', ts_ms / 1000, 'unixepoch'));

-- Monthly aggregate (按需物化, refresh tick 增量更新)
CREATE TABLE month_aggregates (
  provider TEXT NOT NULL,
  model TEXT NOT NULL,
  year_month TEXT NOT NULL,          -- '2026-07' format
  input INTEGER DEFAULT 0,
  output INTEGER DEFAULT 0,
  cache_read INTEGER DEFAULT 0,
  cache_write INTEGER DEFAULT 0,
  reasoning INTEGER DEFAULT 0,
  cost_usd REAL DEFAULT 0,
  last_updated INTEGER,
  PRIMARY KEY (provider, model, year_month)
);

-- PricingTable 缓存 (F2a PricingTable 落地, 这里只缓存 + 加 fetched_at)
CREATE TABLE model_pricing_cache (
  provider TEXT NOT NULL,
  model TEXT NOT NULL,
  input_rate REAL,                   -- ¥/M tokens (F2a PayAsYouGoRate.input)
  output_rate REAL,
  cache_read_rate REAL,
  source TEXT,                       -- 'pricing_table' | 'lite_llm' | 'fallback'
  fetched_at INTEGER,
  PRIMARY KEY (provider, model)
);

-- Schema 版本控制 (5 reference 共识: 不匹配整库 invalid)
CREATE TABLE schema_version (
  version INTEGER PRIMARY KEY
);
INSERT INTO schema_version VALUES (1);
```

### 4.3 5 reference 共识的 dedup key 格式

```swift
// codeburn Cursor 共识: dedupKey 不含 token 数值
// 5 reference 共识格式: "<source>:<session>:<stream>:<msgId>"
func makeSourceId(source: TokenSource, sessionId: String, streamId: String, msgId: String?) -> String {
    let stream = streamId.isEmpty ? "main" : streamId
    let msg = msgId ?? "nolimit"  // 部分 source (Kimi CLI 老) 没 msgId
    return "\(source.rawValue):\(sessionId):\(stream):\(msg)"
}
```

## 5. Provider 归一化规则

```swift
func matchProvider(model: String, providerID: String) -> Provider {
    let m = model.lowercased()
    let p = providerID.lowercased()

    // model 字段为主 (优先级高)
    if m.contains("kimi") || m.hasPrefix("k2p") { return .kimi }
    if m.hasPrefix("claude-") { return .claude }
    if m.hasPrefix("gpt-") || m.hasPrefix("o3-") || m.hasPrefix("o4-") { return .codex }
    if m.hasPrefix("glm-") { return .zai }

    // providerID 辅助 (model 缺失或无法识别)
    if p.contains("kimi") || p.contains("moonshot") { return .kimi }
    if p.contains("anthropic") { return .claude }
    if p.contains("openai") { return .codex }
    if p.contains("z-ai") || p.contains("zai") { return .zai }

    // 兜底 (5 reference 共识: 别 panic, 给个默认值)
    logger.warning("F2b: unknown model '\(model)' providerID '\(providerID)', fallback to .nanoGpt")
    return .nanoGpt
}
```

**为什么 OpenCode 也归 Provider** (不只 Tool)：OpenCode 的 `providerID="kimi"` + `modelID="kimi-for-coding"` 表示"OpenCode 调 Kimi" — **Tool=OpenCode, Provider=Kimi**。F2b 跨 tool 合并同一 provider。

## 6. Pricing Engine

```swift
struct MonthCost {
    let provider: Provider
    let model: String
    let tokens: TokenBreakdown
    let costRMB: Double?            // nil = PricingTable 没匹配
    let inputRate: Double?         // ¥/M tokens
    let outputRate: Double?
    let cacheReadRate: Double?
}

func calculateCost(provider: Provider, model: String, tokens: TokenBreakdown, pricing: PricingTable) -> MonthCost {
    guard let rate = pricing.rate(for: providerEnumToIdentifier(provider))
        .flatMap({ $0 == nil ? nil : $0 })
        ?? pricing.rate(for: .kimi)?.flatMap({ $0 }).flatMap({ _ in nil })  // 简化: 直接 optional
    else {
        return MonthCost(provider: provider, model: model, tokens: tokens,
                        costRMB: nil, inputRate: nil, outputRate: nil, cacheReadRate: nil)
    }
    // F2a PayAsYouGoRate 单位是 ¥/M tokens
    let cost = (Double(tokens.input) * rate.input
              + Double(tokens.output) * rate.output
              + Double(tokens.cacheRead) * (rate.cache ?? 0)) / 1_000_000
    return MonthCost(provider: provider, model: model, tokens: tokens,
                    costRMB: cost, inputRate: rate.input,
                    outputRate: rate.output, cacheReadRate: rate.cache)
}
```

**F2a PricingTable 复用**：F2b 不重写 PayAsYouGoRate struct，直接 `import PricingTable` 调 `rate(for: ProviderIdentifier)`。F2a 已给 6 真 token 工具的 rate（kimi/claude/codex/glm-4.6/gpt-4o），F2b 把 rate 应用到月度聚合 token 数。

**cacheWrite 不计费** (5 reference 共识):
- Anthropic prompt cache write 免费
- OpenAI cache write 0.5x input 价（v1 简化：不计费，标 "简化模型"）
- tokenmeter 实际：cacheWriteTokens 完全不进 cost 累加
- v1 用 tokenmeter 模型

## 7. 数据流

```
[30s tick] ┌─ OpenCodeExtractor.scanAll()
           ├─ ClaudeCodeExtractor.scanAll()
           ├─ CodexExtractor.scanAll()
           ├─ KimiCLILegacyExtractor.scanAll()
           ├─ KimiCodeExtractor.scanAll()
           ├─ ZAIExtractor.fetchUsage()    (API 调)
           └─ NanoGPTExtractor.fetchUsage() (API 调)
                       ↓ (raw TokenEvent, model/providerID 不一定归一化)
           [ProviderNormalizer.normalize(event)]
                       ↓ (provider 归一化后)
           [Store.upsertTokenEvent(event)]   -- INSERT OR IGNORE on source_id
                       ↓
           [MonthAggregator.refresh(year_month)] -- 从 token_events 聚合 month_aggregates
                       ↓
           [PricingEngine.calculate(month_aggregates)]
                       ↓
           [Cache + UI: Menu Bar query]
```

**Refresh 策略**（30s tick）:
- 30s 触发 actor `RefreshTick`:
  1. 并发触发 7 个 TokenExtractor scan（每个 tool 1 个 Task）
  2. 每个 extractor 增量扫（byte offset 增量 + 损坏行跳过）
  3. 归一化后 upsert to `token_events` (dedup by source_id)
  4. 重新聚合 `month_aggregates` for current month
  5. `PricingTable` 缓存 hit 的话用缓存，否则 lazy fetch LiteLLM

**byte offset 增量**（tokenmeter 共识）:
```swift
class IncrementalFileWatcher {
    var seenOffsets: [URL: UInt64] = [:]
    // truncate 检测: currentSize < lastOffset → reset to 0
}
```

## 8. 错误处理

| 场景 | 行为 |
|---|---|
| 5 真 token 工具 某 1 个数据源路径不存在 | 静默 (nil, nil)，不报错（5 reference "user does not have X installed" 约定） |
| JSONL 损坏行 | 跳过该行，继续处理（5 reference 共识） |
| Provider 归一化失败 (model + providerID 都不识别) | 兜底 `.nanoGpt` + logger.warning |
| F2a PricingTable 没匹配 model | `cost = nil` + UI 显示 "未知"（不阻塞其他字段） |
| SQLite 写冲突 (UNIQUE) | INSERT OR IGNORE — 静默跳过重复 source_id |
| Schema 版本不匹配 (未来 v2 加列) | 整库重建 (5 reference 共识) |
| Z.AI / NanoGpt API 调失败 | 显示 "降级不可用" + 其他 source 继续 |
| App restart 后 | SQLite 持久化恢复 month_aggregates，token_events 重新增量扫 |

## 9. UI 形态（macOS Menu Bar v1）

```
┌─────────────────────────────────┐
│ Token King                  ⏻  │  ← 菜单栏 icon
├─────────────────────────────────┤
│ 本月 (2026-07)                  │  ← Calendar month 时间窗
│ ─────────────────────────────  │
│ Kimi          142k token  ¥42   │  ← 需求 1 (token) + 需求 2 (折算)
│   kimi-for-coding   120k  ¥36  │  ← per-model breakdown
│   kimi-k2.5         22k   ¥6   │
│ Claude        1.2M token  ¥2.4k │
│ Codex         800k token  ¥1.8k │
│ Z.AI          320k token  ¥680  │
│ NanoGpt       50k token   ¥0.12 │
│ ─────────────────────────────  │
│ 总计       2.5M token   ¥4.9k  │
│ 订阅参考  ¥1,329/月              │  ← 已有 F2a SubscriptionSettingsManager
│ 节省  ¥... (或超出)             │
└─────────────────────────────────┘
```

**Per-provider 详情**（点击 provider 名展开）:
- 按 model 拆 token 数 + 折算价
- 按 tool 拆 (e.g. "Kimi = OpenCode(120k) + kimi-code(22k)")
- 按 day 拆 (month 内)

## 10. 与已有模块关系

- **F2a `Helpers/PricingTable.swift`** (v2.12.0 落地): F2b 直接 `import` + 调 `rate(for:)`, 不重写
- **`App/StatusBarController.swift:2011`**: 现有 header "额度状态 ¥1329/月" — F2b 在它下面加新行
- **`Helpers/ProviderMenuBuilder.swift:758`**: 现有 tokenUsage % 渲染 — F2b 在单 provider 详情加 "按量折算" row
- **`AppDelegate.swift`**: 加 30s tick RefreshTick actor
- **`App/ModernApp.swift`**: 加 menu bar 顶部新行 (在现有 quota status 之下)
- **`Info.plist`**: 不改

## 11. 测试策略

### 11.1 单元测试 (per task, parallel)

| Task | 单元测试 |
|---|---|
| TokenEvent struct | Codable round-trip, Equatable, hash 唯一性 |
| ProviderNormalizer | 5 个 provider 5 个 model 5 个 providerID 笛卡尔积 = 125 case + 兜底 case |
| OpenCodeExtractor | SQLite 测试 db (in-memory) + 5 sample rows + 跨 channel merge |
| ClaudeCodeExtractor | sample jsonl 5 行 + 5m/1h cache 分段 + 跨 session dir merge |
| CodexExtractor | sample rollout jsonl 5 行 + 5 字段全 + fork replay dedup + prev=null sentinel |
| KimiCLILegacyExtractor | sample context.jsonl 5 行 + 累计 token_count |
| KimiCodeExtractor | sample wire.jsonl (1.10+ 协议) 5 行 + event.usage camelCase 4 字段 |
| ZAIExtractor / NanoGPTExtractor | mock HTTP response (URLProtocol stub) |
| Store (SQLite) | INSERT OR IGNORE dedup + month_aggregates 重新聚合正确性 + schema_version 升级 |
| PricingEngine | 5 个 provider × 5 个 model × 5 个 token 分布 = 125 case + pricing nil 兜底 |
| RefreshTick actor | 7 个 extractor 并发触发 + 损坏数据不阻塞 |

### 11.2 e2e driver test (per 项目 "UI bug 必须 e2e" 规则)

- **Test 1**: 启动 app → 等 30s tick → 打开 menu bar → 看到 "本月 API 折算 ¥XXX" + provider 列表
- **Test 2**: 在 OpenCode 跑一个 session → 等 30s tick → 看到 token 数 + 折算价 增量更新
- **Test 3**: 跨 calendar month (mock 时间) → 验证 reset 行为
- **Test 4**: 5 真 token 工具 + 2 降级 provider 同时存在 → 验证 provider 归一化跨 tool 合并

### 11.3 Regression 验证

- 414+8 = 422 existing tests 不破 (F2a 已有)
- 8 + 新增 TokenEvent / PricingEngine / 5+2 TokenExtractor / Store / RefreshTick / UI 单元测试 + e2e
- 总目标: ~500+ tests passing

## 12. 范围外 (Out of Scope, F2b v1 不做)

- ❌ **桌面小部件 (Desktop Widget)** — v2。F2b v1 只 Menu Bar
- ❌ **跨 provider 趋势图 / 多年月对比** — 单月数据
- ❌ **LiteLLM 24h cache 自动刷新** — F2b v1 启动时拉一次，browse-later；实时刷新 F2c
- ❌ **F2c 跨 provider 汇总视图** — 独立 spec
- ❌ **预算告警 (Budget alerts)** — v3
- ❌ **CSV / JSON 导出** — v3
- ❌ **11 个其他 source (Cursor / Goose / Hermes / Kilo / Amp / 等)** — v2 评估
- ❌ **FSEvents file watcher** — v1 30s tick 够，v2 评估
- ❌ **Web dashboard / SaaS 化** — 完全 out of scope
- ❌ **Token budget per project / team** — 单用户工具，无需

## 13. 实施步骤 (high-level, plan 阶段详细化)

### Phase 1: 数据层 (3 task, 估 2-3 天)
1. **Task 1**: `Helpers/TokenEvent.swift` — TokenEvent / TokenBreakdown / Provider / TokenSource structs + 单元测试
2. **Task 2**: `Helpers/TokenNormalizer.swift` — matchProvider 函数 + 125 case 单元测试
3. **Task 3**: `Helpers/TokenExtractor/` 7 个适配器 + 各自测试 (5 真 + 2 降级)

### Phase 2: 存储 + 计算 (2 task, 估 1-2 天)
4. **Task 4**: `Helpers/TokenUsageStore.swift` (actor) — SQLite schema + INSERT OR IGNORE + 30s tick refresh + 单元测试
5. **Task 5**: `Helpers/MonthCostCalculator.swift` — F2a PricingTable 集成 + calculate 函数 + 125 case 测试

### Phase 3: UI (2 task, 估 1-2 天)
6. **Task 6**: `App/StatusBarController.swift` + `Helpers/ProviderMenuBuilder.swift` UI 修改 (per Section 9 设计)
7. **Task 7**: e2e driver test (Xcode UI test) — 4 个 test case (per Section 11.2)

### Phase 4: Ship (1 task, 估 0.5 天)
8. **Task 8**: CLAUDE.md signal + version bump v2.12.0 → v2.13.0 + push

**总估时 4-7 天**（subagent-driven，每个 task 1-2 subagent）。

## 14. 风险 / 已知 Trade-off

| 风险 | 接受 / 缓解 |
|---|---|
| Hardcode PayAsYouGoRate 过期 | F2a 接受 (有 follow-up: P3 monthly review)，F2b 复用 |
| Kimi wire 协议 1.0/1.3/1.4 无 token_usage 字段 | F2b v1 降级: Kimi code 1.0 session 不算 (只算 1.10+)，显示"数据需更新 Kimi Code" |
| OpenCode message.data 与 session 表数据不一致 | F2b 只读 message.data (per-message 准)，session 表作 fallback |
| Codex fork replay 重复计数 | 学 tokscale 用 UUID v7 + task_started 标志 (ccusage + codeburn 共识) |
| 5 真 token 工具 数据格式变化 | SQLite schema_version 1 → 2 时整库 invalid + 用户提示 |
| 30s tick 期间 app 关闭 | SQLite 持久化跨重启，month_aggregates 缓存 |
| Desktop widget 路径 (v2) | F2b v1 留 Menu Bar，UI 层不抽象 Widget 渲染 (避免 premature) |

## 15. Acceptance Criteria

- [ ] 7 个 TokenExtractor 全部能 parse 真实工具数据 (OpenCode SQLite / Claude Code jsonl / Codex rollout / 老 kimi-cli context / 新 kimi-code wire / Z.AI API / NanoGpt API)
- [ ] Provider 归一化: 5 真 token 工具跨 tool 同 provider 数据合并 (e.g. Kimi = OpenCode + kimi-code)
- [ ] 30s tick 增量: token 数实时更新, 损坏行不阻塞其他源
- [ ] SQLite 持久化: app 重启后 month_aggregates 仍存在, 不用重算
- [ ] F2a PricingTable 集成: 6 真 token 工具的 rate 应用到月度 token 数 = 月度折算价
- [ ] Menu Bar UI: 顶部显示 "本月 API 折算 ¥XXX" + per-provider 列表 + 详情展开
- [ ] Calendar month 时间窗: 7/31 → 8/1 时正确 reset
- [ ] e2e driver test 4 个 test case 全 pass
- [ ] 总 tests ≥ 500 passing, 0 fail, 0 regression
- [ ] F2a 8 tests 仍全 pass
- [ ] commit message 英文 (per AGENTS.md 项目规则)
- [ ] CLAUDE.md signal + version bump v2.12.0 → v2.13.0 + push

## 16. 相关文件位置

- `Helpers/PricingTable.swift` (F2a v2.12.0 落地)
- `Helpers/PricingTableTests.swift` (F2a 8 tests)
- `App/StatusBarController.swift:2011` — 顶部 header 现有 "额度状态"
- `Helpers/ProviderMenuBuilder.swift:758` — 单 provider 详情现有 tokenUsage 渲染
- `App/AppDelegate.swift` — 加 30s tick RefreshTick actor
- `App/ModernApp.swift` — menu bar 顶部新行
- `docs/superpowers/specs/2026-07-07-f2a-pay-as-you-go-pricing-table-design.md`
- `docs/handoffs/2026-07-08-f2b-session-handoff-2.md`
- `docs/superpowers/research/f2b-reference-research-2026-07-08.md`

---

## Spec Self-Review (per brainstorming skill 第 7 步)

- **Placeholder scan**: 没有 "TBD" / "TODO" / "待定" 残留
- **Internal consistency**: 4 decision (Section 2) ↔ Architecture (Section 3) ↔ Schema (Section 4) ↔ UI (Section 9) ↔ Acceptance (Section 15) 一致
- **Scope check**: Section 12 明确 out-of-scope，Section 13 实施步骤 scope 严格
- **Ambiguity check**: 每个字段/方法都有具体定义；cacheWrite 不计费在 Section 6 明确

无 issue。Spec ready for user review (per brainstorming skill 第 8 步)。
