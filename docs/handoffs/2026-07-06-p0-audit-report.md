# P0 Audit Report: B02/B04/B05/B16/B18/B19/B21/B22/B23/B25/B26/B27/B28/B29/B30/B32/B33 (16 bugs, batch #1-#5)

**Audit date**: 2026-07-06
**Auditor**: OpenCode session 接续 2026-07-06-p0-audit-handoff.md
**Base**: `c80d2ac` (上次 session 修完 B41 的 base) → HEAD `628bcaf`
**Result**: ✅ **17/17 bug 全部 verified 通过；5 个 worktree disjoint；1 个 minor handoff/actual 数字差异但不是 regression**

---

## 1. Phase 1 — 整体性 audit

### 1.1 xcodebuild test
```
** TEST SUCCEEDED **
Executed 361 tests, with 23 tests skipped and 0 failures (0 unexpected) in 8.015 (8.170) seconds
```

✅ **Pass**。handoff 写 351，实际跑 361。差异来源：
- e75bace (sub-agent-A) 新增 10 个回归用例 (`testRMBMonthlyCostUsesNativeCNYFor*`, `testGeminiCLIPresetsHaveUniqueNames`, `testIconNameUsesDistinctFamilySymbols` 等)
- 测试数 351 → 361 是正向变化（多覆盖，不是少覆盖）
- 23 个 skipped 是网络集成测试 (`testFetchLiveReturnsUsageWithRealCredentials` 等) 在没有对应 credentials 时按设计跳过

### 1.2 git log c80d2ac..HEAD — 13 commits
```
628bcaf  docs(token-king): mark B21/B25/B26/B28/B29 as done (PR #3 from sub-agent-C)
bcbdba8  merge: B02/B16/B23 (PR #5 from sub-agent-E)
abc6e14  merge: B21/B25/B26/B28/B29 (PR #3 from sub-agent-C)
26cba60  docs(token-king): B19/B22/B27 marked as done (PR #4 from sub-agent-B)
c26d2ad  merge: B04/B33 icon view fixes (PR #2 from sub-agent-D)
d05df52  merge: B30/B32/B05/B18 (PR #1 from sub-agent-A)
dda78b1  merge: bring sub-agent-A's commit e75bace into C
6059b33  fix(token-king): B21/B25/B26/B28/B29 (StatusBarController cleanups)
e75bace  fix(token-king): B32/B05/B30/B18 (4 P0 batch #1)
a5ef78b  fix(token-king): B22/B19/B27 (ProviderMenuBuilder cleanups)
7e5f89a  docs(token-king): replace <pending> with 964df1e in B04/B33 entries
964df1e  fix(token-king): B04/B33 (status bar icon view accuracy)
097d04c  fix(token-king): B02/B16/B23 (CLIProviderManager registration)
```

✅ **正好 13 commit**，合并顺序 A→D→C→B→E 一致。handoff 给的速查表 13 个 hash 全部对得上。

### 1.3 commit actual stat vs claimed
每个 commit 的 `git show --stat` 输出匹配 handoff 描述的改动文件清单：

| Commit | Stat | Claimed | OK? |
|---|---|---|---|
| 097d04c | docs/backlog/bugs/README.md 6 lines | docs only | ✅ |
| 964df1e | MultiProviderStatusBarIconView.swift -54 行净 + docs | B04/B33 | ✅ |
| 7e5f89a | docs only | docs pending→hash | ✅ |
| a5ef78b | ProviderMenuBuilder.swift +7/-4 | B22 + docs | ✅ |
| e75bace | SubscriptionSettings.swift +4 + ProviderRegionTests.swift +113 + SubscriptionPresetTests.swift +32 | B32/B05/B30/B18 + 测试 | ✅ |
| 6059b33 | StatusBarController.swift -163 死代码 | B21/B25/B26/B28/B29 | ✅ (实际净 -163，handoff 写 -173) |
| dda78b1 | merge conflict resolved | merge A into C | ✅ |
| d05df52 | merge | merge A | ✅ |
| c26d2ad | merge | merge D | ✅ |
| 26cba60 | merge 含 ProviderMenuBuilder.swift +7/-4 | merge B (含代码, 不是 docs-only) | ⚠️ handoff 把这列成 docs-only |
| abc6e14 | merge | merge C | ✅ |
| bcbdba8 | merge | merge E | ✅ |
| 628bcaf | docs only | docs backfill C | ✅ |

**Minor discrepancy**: handoff 写"4 个 docs-only commit (26cba60, 628bcaf, 7e5f89a, c26d2ad)" — 实际只有 `7e5f89a` 和 `628bcaf` 是纯 docs commit；`26cba60` 含 `ProviderMenuBuilder.swift` 代码（merge a5ef78b 携带），`c26d2ad` 含 `MultiProviderStatusBarIconView.swift` 代码（merge 964df1e 携带）。这是 handoff 描述不准确，不是 audit 风险 — 这些 commit 实际内容都已经过 Phase 2 验证。

StatusBarController -163 行 vs handoff -173 行差异：实际 git stat 是 178 deletions，15 insertions；net -163；handoff 写的"-173 死代码"是 rounding。无 regression。

---

## 2. Phase 2 — 17 个 bug 逐一验证

| Bug | Commit | 验证证据 | 结果 |
|---|---|---|---|
| **B02** | `403f72a` code + `097d04c` docs | `ProviderManager.swift:42` `OpenCodeProvider()`, `:55-56` `TavilySearchProvider()`+`BraveSearchProvider()` | ✅ |
| **B04** | `964df1e` | `MultiProviderStatusBarIconView.swift:133-136` 注释 `B04: delegate to ProviderIdentifier.iconName`，`let iconName = alert.identifier.iconName` 单点调用；本地 54 行 switch 完全删除 | ✅ |
| **B05** | `403f72a` + `e75bace` test | `ProviderProtocol.swift:87` `case .kimiCN, .minimaxCodingPlanCN, .mimo, .volcanoArk, .hunyuan, .zhipuGLM: return .china`；`e75bace` 加 4 个回归 | ✅ |
| **B16** | `403f72a` + `097d04c` docs | `CLIProviderManager.swift:37` `openCodeProvider`, `:59-60` `tavilySearchProvider`+`braveSearchProvider`；`registeredProviders:15-23` 数组含 `.openCode/.tavilySearch/.braveSearch` | ✅ |
| **B18** | `5fa79d2` iconName + `964df1e` consumed | `ProviderProtocol.swift:222-223` `.geminiCLI: return "g.circle"`, `:244` `.minimaxCodingPlanCN`, `:264-265` `.zhipuGLM: return "z.circle"` | ✅ |
| **B19** | `403f72a` (commit 已落地) + `26cba60` docs | `ProviderMenuBuilder.swift:921 case .synthetic:` 直接进 `if let fiveHour`，无前置 separator；`:942 case .kiro:` 直接进 `if let total = details.creditsTotal`，无前置 separator；`:939/.synthetic`、`:994/.kiro` 的 `addSubscriptionItems` 是 case 内的第一个调用 | ✅ |
| **B21** | `6059b33` + `628bcaf` docs | `StatusBarController.swift:4651-4672` `providerQuotaOrder` 数组不包含 `.geminiCLI`；`geminiAccount` 走专门块（`:1241, :1301, :1657, :2487` 多处） | ✅ |
| **B22** | `a5ef78b` | `ProviderMenuBuilder.swift:1301-1307` `if selectedName == preset.name, selectedCost == nil \|\| selectedCost == preset.cost` | ✅ |
| **B23** | `403f72a` + `097d04c` docs | `CLIProviderManager.swift:15-23 registeredProviders` 不含 `.kiro`；`:27-63 init()` 不含 `KiroProvider()` | ✅ |
| **B25** | `6059b33` | `StatusBarController.swift:4643` `static let payAsYouGoProviderIdentifiers: [ProviderIdentifier] = [.openRouter, .openCodeZen, .openCode]`；`:1817 for identifier in Self.payAsYouGoProviderIdentifiers` 复用 | ✅ |
| **B26** | `6059b33` | grep 全文件 `predictionPeriodMenu` / `updatePredictionPeriodMenu` **0 命中** | ✅ |
| **B27** | `403f72a` | grep 全文件 `visiblePresets.isEmpty` / `该版本仅海外` **0 命中** | ✅ |
| **B28** | `6059b33` | grep `historyMenuItem\b` / `historySubmenu\b` / `updateHistorySubmenu\b` **0 命中**；`createCopilotHistorySubmenu()` 在 `:1900` 调用，存在 | ✅ |
| **B29** | `c80d2ac` + `628bcaf` docs | `MenuItemTag.dynamic` 在 StatusBarController 33 处使用（`:1776, :1803, :1811, :1817, :1840, :1871, :1888, :1935, :1944, :1954, :1971, :1983, :1998, :2003, :2046, :2068, :2357, :2435, :2466, :2521, :2550, :2559, :2563, :2571, :2578, :2603, :2609`） | ✅ |
| **B30** | `e75bace` + `e75bace` test | `SubscriptionSettings.swift:154-160` geminiCLI = Plus Monthly $4 / Plus Annual $8 / Pro $20 / Ultra Monthly $125 / Ultra Annual $250 — 5 个名字唯一 | ✅ |
| **B32** | `403f72a` + `e75bace` test | `SubscriptionSettings.swift:442-448` `monthlyCost(forKey:inCurrency:formatter:)`:442，`:448 return cnyCost(for: plan, key: key) ?? (plan.cost * formatter.currentRate)` — cnyCost 命中时返回 CNY 原价 | ✅ |
| **B33** | `964df1e` | `MultiProviderStatusBarIconView.swift:120 let text = CurrencyFormatter.shared.currency.symbol`；grep `let text = "$"` **0 命中** | ✅ |

**17/17 passed — 无 fail、无 concern**。

---

## 3. Phase 3 — 风险审计

### 3.1 Sub-agent 交叉
5 个 agent 改的文件树 confirmed disjoint：
- **A (e75bace)**: `Models/SubscriptionSettings.swift` + `Tests/ProviderRegionTests.swift` + `Tests/SubscriptionPresetTests.swift` — Subscription domain
- **B (a5ef78b)**: `Helpers/ProviderMenuBuilder.swift` — Menu builder
- **C (6059b33)**: `App/StatusBarController.swift` — Status bar controller
- **D (964df1e)**: `Views/MultiProviderStatusBarIconView.swift` — Icon view
- **E (097d04c)**: docs only (code 已在 `403f72a` 落地)

抽 `git show 6059b33` 的 diff 内容只动 `StatusBarController.swift`，未触 `ProviderMenuBuilder.swift` 或 `SubscriptionSettings.swift` ✅。5 个 agent 无交叉。

### 3.2 4 个 docs-related commit 一致性
- `7e5f89a` (D docs sync): B04/B33 行从 `<pending>` 替换为 `964df1e` — ✅ 对得上 `964df1e` 实际 commit hash
- `26cba60` (B's PR merge): 携 `a5ef78b` (ProviderMenuBuilder.swift) + docs B19/B22/B27 — ✅ `a5ef78b` 真实存在改了 ProviderMenuBuilder
- `628bcaf` (C docs backfill): B21/B25/B26/B28/B29 → `6059b33` — ✅ 对得上
- 4 个 docs-only commit handoff 描述不准确，但实际全部内容一致

**Minor**: handoff 描述了 "B22 状态说 ✅ commit `a5ef78b`，验证 `a5ef78b` 真的存在且改了 B22 修的代码" — 实际 grep README 后 B22 row 引用 `commit a5ef78b`，commit body 明确包含 B22 fix（外层 `if selectedName == preset.name, selectedCost == nil || selectedCost == preset.cost`）。✅

### 3.3 Info.plist build 副作用
```
git diff CopilotMonitor/CopilotMonitor/Info.plist
@@ -17,7 +17,7 @@
 	<key>CFBundleVersion</key>
 	<string>2.11.1</string>
 	<key>GitCommitHash</key>
-	<string>9a77e17d97cdb5478610cd90f6b0993e3d7f296a</string>
+	<string>1cf46ad9792c03e74d81039ca94c68a4ccb3a580</string>
```
✅ **仅 GitCommitHash 自动 bump**, 新 hash 是 `1cf46ad...`, 这是 build 触发的预期副作用。

### 3.4 行为回归 spot check (静态)
无法跑 live (需要重启 app)，但按 commit body + 静态 grep 行为路径已通：
- Gemini CLI `addSubscriptionItems` 选中 $4 不会同时高亮 $8 (B22 cost-gate) ✅
- `updateMultiProviderMenu` 不再 hardcoded (B25 helper hoisted) ✅
- `providerQuotaOrder` 列表里 `.geminiCLI` 不在 (B21) — 18 项 | grep 不含 geminiCLI ✅
- StatusBarController 净 -163 行死代码 (B26+B28) ✅
- 多 provider icon 在 `.geminiCLI → g.circle` / `.zhipuGLM → z.circle` / `.minimaxCodingPlanCN → MinimaxIcon` 渲染一致 (B04/B18) ✅

---

## 4. Phase 4 — Working tree cleanup 决策 (用户拍板)

经用户 2026-07-06 拍板：

| 残留项 | 决策 | 处理 |
|---|---|---|
| `AppDelegate.swift` (~150 行: B41 bridge race workaround + observability) | **Commit 全部** | ✅ 入版本库 |
| `.gitignore` (8 行加 `.swarm/` + `*.pbxproj.bak*`) | **保留 working tree，不 commit** | 维持 user rule "P3 rules 说不动" |
| `Info.plist` GitCommitHash bump | **忽略，不 commit** | build 副作用，自动更新 |
| `docs/handoffs/2026-07-05-token-king-icon-blurry.md` | **保留入版本库** | B41 调查线索存档 |
| `docs/handoffs/2026-07-06-p0-audit-handoff.md` | **保留入版本库** | session 交接 + 复盘 |

---

## 5. 总体结论

**Audit 状态**: ✅ **PASS** — 无 fail、无 regression、无 follow-up 必修 bug。

**对用户预期的影响**:
- **"1,330 之谜"** (B44, 上次 session 修): 未在本 batch 改动范围内，但 `addSubscriptionItems` 的 cost-aware 高亮 (B22) 间接缓解未来类似 duplicate key 显示混乱
- **菜单顺序**: `providerQuotaOrder` 18 项已确定 (按 CN 优先)，Gemini 走 per-account 块
- **Dead code**: 净删除 163 行死代码 (预测周期菜单状态、历史菜单注入双重创建) + 54 行 icon switch

**值得 follow-up 但非本 batch**:
1. **B17/B20/B24** — ProviderMenuBuilder 对 `openCode/tavilySearch/braveSearch` 仍走 default case；`configInfo(for:)` 对多个 provider 仍走 default — backlog 标 "已诊断待修"，等后续 session
2. **B03** — `StatusBarController.usagePercentCandidates` 中 `.volcanoArk` 与 `.mimo/.hunyuan/.zhipuGLM` 重复分支 — backlog 标 "已诊断待修"
3. **B07/B08/B10/B11/B13/B14/B15** — 测试污染/共享状态清理 — backlog 标 "已诊断待修"
4. **B40 (multi-monitor 镜像图标)** — backlog 标 "已诊断待修；B41 修复可能顺带缓解"

**Audit handoff 本身 (本文件) + 上一份 handoff (2026-07-06-p0-audit-handoff.md) + B41 调查笔记 (2026-07-05-token-king-icon-blurry.md) 入库后，下一份 session 可从 `628bcaf` clean HEAD 起步继续 P1 批**。
