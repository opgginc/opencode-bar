# F2b Session Handoff #2 — 2026-07-08

> Source: 2026-07-08 session, after F2a 5 commits landed (v2.12.0).
> Status: **F2b v1 data foundation 100% verified** (实际跑 python 累加), 走 spec+plan 暂未开始.

## F2a 状态（已闭环）

5 commits on `main` pushed to origin:
- `d443677` chore: bump v2.12.0
- `57a09db` build: pbxproj 8 处注册
- `87c4ef7` feat: PricingTable.swift + 8 tests
- `f82b424` docs: implementation plan
- `3701162` docs: spec

测试 414→422, 19 skipped, 0 fail.

## F2b v1 关键发现（这次 session）

**User 关键 insight 推动**：不看 ProviderUsage 推算，直接读工具本地 session 文件拿真 token 数据。

### 5 真 token 工具（实际跑 python 累加 verified）

| 工具 | 文件路径 | token 字段 | model 字段 | 实际统计 |
|---|---|---|---|---|
| **OpenCode** | `~/.local/share/opencode/opencode.db` (SQLite) | `session.tokens_input/output/reasoning/cache_read/cache_write` | `session.model` | 362 sessions · $164.25 cost · 10 models (minimax-m3, mimo-v2.5-pro, deepseek-v4-pro 等) |
| **Claude Code** | `~/.claude/projects/<encoded-cwd>/<sessionId>.jsonl` | `message.usage.{input_tokens, output_tokens, cache_creation_input_tokens, cache_read_input_tokens}` | `message.model` | 2,250 files · 14,597 messages · 5 models (opus-4.8 1.8B, haiku-4.5 67M, mimo-v2.5-pro 552K) |
| **Codex CLI** | `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` | `payload.info.total_token_usage.{input_tokens, output_tokens, cached_input_tokens}` | `payload.turn_context.model` (每次 turn 重置) 或 `~/.codex/config.toml` 顶部 `model` | 326 files · 12,552 events · gpt-5.4-mini 主 |
| **老 kimi-cli** | `~/.kimi/sessions/<workdir-hash>/<session-id>/context.jsonl` | `{"role":"_usage", "token_count": N}` | ❌ **无字段**（user 固定用 kimi-for-coding） | 9 files · 5 sessions · 64K 累计 |
| **kimi-code (新)** | `~/.kimi-code/sessions/<workdir-hash>/<session-id>/agents/main/wire.jsonl` | `event.usage.{inputOther, output, inputCacheRead, inputCacheCreation}` (**camelCase**!) + 顶层 `usage.*` + `tokensUsed/Before/After` | `event.model` 字段**有 3847 次但 value 全空/None**（Kimi wire 协议设计不存 model） | 34 files · 24,743 lines · 3,835 events · **14.4M input + 1.4M output + 473M cache_rd** |

### 2 降级

- **Z.AI Coding Plan** — provider API 调（`https://api.z.ai/...`）
- **NanoGpt** — provider API 调（OpenAI-compatible API）

### Kimi model 降级方案（已 verified，codeburn 实现）

按 `KIMI_MODEL_NAME` env → `~/.kimi/config.toml` `default_model` (user 实际 = "kimi-for-coding") → `kimi-auto` 兜底。

> source: https://raw.githubusercontent.com/getagentseal/codeburn/master/docs/providers/kimi.md
> "The current Kimi wire schema does not persist the model on every usage update."

## 关键 search 引用

- **tokenmeter** (Go, 24⭐): https://github.com/tt-a1i/tokenmeter — 15 source including Kimi
- **codeburn** (TypeScript, 8.4K⭐): https://github.com/getagentseal/codeburn — 31 tools, 真实实现了 Kimi 模型降级
- **tokscale** (Rust, 4K⭐): https://github.com/junhoyeo/tokscale — Kimi wire StatusUpdate parse
- **MoonshotAI/kimi-cli** issue #2394: StatusUpdate.token_usage 在 ACP server 模式被丢弃，但 wire.jsonl 仍记录
- **kimi-cli wire mode docs**: https://moonshotai.github.io/kimi-cli/en/customization/wire-mode.html
- **kimi-cli wire types.py**: https://github.com/MoonshotAI/kimi-cli/blob/main/src/kimi_cli/wire/types.py (StatusUpdate model 字段)
- **ccusage Kimi guide**: https://ccusage.com/guide/kimi/

## 教训（落库）

- 之前搜 `token_usage` (snake_case) 找 kimi-code token 字段，0 results — **字段实际是 camelCase `inputOther`/`output`/`inputCacheRead`/`inputCacheCreation`**。教训：扫字段时**用 Counter 列所有 unique keys + 频次**，不要靠猜字段名
- 之前只看 `context.append_message` 类型行（user/assistant 消息），没看 `event` 类型行（StatusUpdate 实际数据）。教训：**先列所有 unique 顶级 type + key，不要按一种类型 grep**
- Kimi wire 协议 1.0/1.3/1.4 **没 token_usage 字段**（`event.usage.*` 在 1.10+ 才有）。但 Rust kimi-code (新) 跟 kimi-cli (Python) **字段名风格不同**（camelCase vs snake_case）— 实现要 2 套

## F2b v1 仍待做

- [ ] 写 F2b spec: `docs/superpowers/specs/2026-07-08-f2b-subscription-vs-pay-as-you-go-ui.md`
- [ ] 写 F2b plan: `docs/superpowers/plans/2026-07-08-f2b-subscription-vs-pay-as-you-go-ui.md`
- [ ] 实现 subagent-driven:
  - Token extractor (5 真工具各一个)
  - PricingTable 集成（已有 v2.12.0）
  - UI: 单 provider 详情 + 顶部 header
  - 跨 provider 汇总 (F2c 后续)
- [ ] e2e driver test (per 项目 "UI bug 必须 e2e driver test" 规则)
- [ ] CLAUDE.md signal + version bump v2.12.0 → v2.13.0

## 关键文件位置

- `Helpers/PricingTable.swift` — F2a 已落地（6 真 token 工具数据基础）
- `Helpers/PricingTableTests.swift` — F2a 8 tests
- `App/StatusBarController.swift:2011` — 顶部 header "额度状态 ¥1329/月"
- `App/StatusBarController.swift:4335-4370` — `aggregatedDailyCosts` in-memory 模式参考
- `Helpers/ProviderMenuBuilder.swift:758-768` — tokenUsage % 单 provider 详情渲染位置
- `docs/superpowers/specs/2026-07-07-f2a-pay-as-you-go-pricing-table-design.md` — F2a 设计
- `docs/handoffs/2026-07-07-b44-session-handoff.md` — 上一 session 上下文

## 不立即开始 F2b 的理由

1. user "先暂停" 信号
2. context 风险（5 真工具数据基础 verified 但实现还有 5-7 task 没跑）
3. F2b v1 实际是 UI 层，需要 e2e driver test（Xcode 跑 + 截图）
4. F2c 跨 provider 汇总依赖 F2b 落地

## 长期项目状态

- 当前 HEAD: `f990a36` (F2b session handoff #1) — 等 F2b spec/plan/implementation 写完会再加 commits
- 当前版本: v2.12.0 (F2a 落地)
- 下次 version bump: v2.13.0 (F2b)
- Fork 落后 upstream/main 4 commits (intentional)
- P3 dirty: `.gitignore` + `Info.plist` 的 `GitCommitHash` (按项目规则不 commit)
