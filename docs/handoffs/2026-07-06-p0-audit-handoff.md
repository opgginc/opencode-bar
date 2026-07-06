# Handoff: 审计 P0 batch #1-#5 的所有改动

## 项目背景
- **仓库**: `/Users/simengyu/projects/usage-deck/` — Token King fork of `opgginc/opencode-bar`
- **当前 main HEAD**: `628bcaf` (本 session 起点 `c80d2ac` = 上次 session 留下的 B42/B43/B44)
- **bundle id**: `com.tokenking.app`
- **build/test 命令**:
  ```bash
  cd /Users/simengyu/projects/usage-deck
  xcodebuild -project CopilotMonitor/CopilotMonitor.xcodeproj -scheme CopilotMonitor \
      -configuration Debug -derivedDataPath /tmp/tk-derived test
  ```
- **用户偏好**: 中文 commit message (fork 习惯), `fix(token-king):` 前缀, 全部用户可见文本英文

## 本 session 做了什么
5 个 git worktree 并行 5 个 sub-agent，每个管独立文件树，处理 16 个 P0 bug。merge 顺序：A → D → C → B → E，2 次 docs 冲突手工解决。351/351 测试通过，final commit `628bcaf`。

## 改动文件清单
```
CopilotMonitor/CopilotMonitor/Models/SubscriptionSettings.swift       | 4 +-
CopilotMonitor/CopilotMonitor/Helpers/ProviderMenuBuilder.swift     | 7 +-
CopilotMonitor/CopilotMonitor/App/StatusBarController.swift        | 183 ++- (-173 行死代码)
CopilotMonitor/CopilotMonitor/Views/MultiProviderStatusBarIconView.swift | 70 -- (-54 行 switch)
CopilotMonitorTests/ProviderRegionTests.swift                       | 113 ++
CopilotMonitorTests/SubscriptionPresetTests.swift                    | 32 ++
docs/backlog/bugs/README.md                                         | 36 +- (状态更新)
```

## Working tree 残留（**不要 commit**）
```
 M .gitignore                                                 (P3 rules, 用户规则说不动)
 M CopilotMonitor/CopilotMonitor/App/AppDelegate.swift         (B39/B40 observability, 上次 session 遗留)
 M CopilotMonitor/CopilotMonitor/Info.plist                    (auto-bumped GitCommitHash, build 副作用)
?? docs/handoffs/2026-07-05-token-king-icon-blurry.md         (本 session 前的诊断笔记)
```

## 你的任务

### Phase 1: 整体性 audit
1. **跑完整测试**确认无 regression:
   ```bash
   cd /Users/simengyu/projects/usage-deck
   xcodebuild -project CopilotMonitor/CopilotMonitor.xcodeproj -scheme CopilotMonitor \
       -configuration Debug -derivedDataPath /tmp/tk-derived test 2>&1 | tail -5
   ```
   应该看到 `** TEST SUCCEEDED **` + 没有 failed 计数。

2. **git log 一致性**: `git log --oneline c80d2ac..HEAD` 应该正好 13 个 commit (5 fix + 5 merge + 2 docs + 1 final docs backfill)。

3. **每个 commit 实际改了啥**: `git show <hash> --stat` — 验证 claimed 改动跟实际 diff 一致。

### Phase 2: 每个 bug 验证

| Bug | Commit | 验证什么 |
|---|---|---|
| **B04** | `964df1e` | `MultiProviderStatusBarIconView.swift` 应删 ~54 行本地 switch，改用 `alert.identifier.iconName`；`ModernStatusBarIconView.swift` 应该**没动**（commit `9a77e17` 已删它并合入 AppKit） |
| **B05** | `403f72a` (code) + `e75bace` (test) | `ProviderProtocol.swift` 的 `var region` switch 应该有 `.mimo/.volcanoArk/.hunyuan/.zhipuGLM → .china` |
| **B18** | `5fa79d2` (iconName) + `964df1e` (consumed by B04) | `ProviderProtocol.iconName` 应该是 `.geminiCLI → g.circle` / `.zhipuGLM → z.circle` / `.minimaxCodingPlanCN → MinimaxIcon` |
| **B19** | `403f72a` (code) + `26cba60` (docs) | `Helpers/ProviderMenuBuilder.swift` 里 `.synthetic` / `.kiro` case 不应再手动 `addItem(NSMenuItem.separator())` 在调 `addSubscriptionItems` 之前 |
| **B21** | `6059b33` (code) + `628bcaf` (docs) | `StatusBarController.providerQuotaOrder` 应该**不含** `.geminiCLI`；Gemini 走专门的 per-account 块（grep `geminiAccount` 验证） |
| **B22** | `a5ef78b` | `addSubscriptionItems` 外层 `if selectedName == preset.name` 应增补 `selectedCost == nil \|\| selectedCost == preset.cost` |
| **B25** | `6059b33` | `StatusBarController.payAsYouGoProviderIdentifiers` helper 应存在；`updateMultiProviderMenu` 应使用它而非 hardcoded `[.openRouter, .openCodeZen, .openCode]` |
| **B26** | `6059b33` | `predictionPeriodMenu` 属性、`setupMenu` 中的初始化代码、`updatePredictionPeriodMenu()` 函数应**全部不存在** |
| **B27** | `403f72a` (code) + `26cba60` (docs) | `addSubscriptionItems` 中 `visiblePresets.isEmpty` 的「该版本仅海外」分支应**不存在** |
| **B28** | `6059b33` | `historyMenuItem` / `historySubmenu` 属性、`updateHistorySubmenu()` 整段应**不存在**；但 `createCopilotHistorySubmenu()` 应存在（活历史 UI） |
| **B29** | (前 session) + `628bcaf` (docs) | `MenuItemTag.dynamic = 999` 命名常量应存在；`updateMultiProviderMenu` 应使用 `MenuItemTag.dynamic` 而非字面 `999` |
| **B30** | `e75bace` (code) + `e75bace` (docs) | `ProviderSubscriptionPresets.geminiCLI` 应该有 5 个**名字不同**的 preset (Plus Monthly / Plus Annual / Pro / Ultra Monthly / Ultra Annual) |
| **B32** | `403f72a` (code) + `e75bace` (test) | `monthlyCost(.rmb)` 应在 cnyCost 命中时返回 CNY 原价（不是 USD × rate）；回归测试 `testRMBMonthlyCostUsesNativeCNYForVolcanoArk/Hunyuan/ZhipuGLM` 应用 rate=7.25 验证不会双重折算 |
| **B33** | `964df1e` | `MultiProviderStatusBarIconView.drawDollarIcon` 不应有 `let text = "$"` 字面量；应改用 `CurrencyFormatter.shared.currency.symbol` |
| **B02** | `403f72a` (code) + `097d04c` (docs) | `ProviderManager.makeDefaultProviders()` 包含 `OpenCodeProvider()`；`CLI/CLIProviderManager.registeredProviders` 跟 `init()` 的 providers 数组对齐（都含 `OpenCode`/`TavilySearch`/`BraveSearch`，都不含 `.kiro`） |
| **B16** | `403f72a` (code) + `097d04c` (docs) | 同 B02 的子集 — 重点看 `CLI/CLIProviderManager.swift` 的 `let xxxProvider` 跟 `registeredProviders` 顺序一致 |
| **B23** | `403f72a` (code) + `097d04c` (docs) | `CLI/CLIProviderManager.swift` 不应包含 `.kiro` / `KiroProvider()` |

### Phase 3: 风险审计

1. **Sub-agent 交叉**: 5 个 agent 改的文件树 disjoint，理论上无代码交叉。但要验证:
   - 看每个 agent 报告里 "实际改了什么" 跟 git diff 实际是否一致
   - 检查 `git show 6059b33` 里 StatusBarController **没有意外** 改到 ProviderMenuBuilder/SubscriptionSettings

2. **手动 docs merge 正确性**: 看 4 个 docs-only commit (26cba60, 628bcaf, 7e5f89a, c26d2ad) 跟实际代码改动的 commit 编号一致性
   - 例如 B22 状态说 ✅ commit `a5ef78b`，验证 `a5ef78b` 真的存在且改了 B22 修的代码

3. **build 副作用残留**: `CopilotMonitor/Info.plist` 的 GitCommitHash 自动 bump，每次 build 都会改。这是预期行为——`git diff` 应该只看到这一行变化。验证:
   ```bash
   git diff CopilotMonitor/Info.plist
   ```
   看到 1 行变化（commit hash）就 OK。

4. **行为回归**: 跑 `xcodebuild test` 后，手工 spot check 几个关键路径:
   - `addSubscriptionItems` 对 Gemini CLI (Plus $4 vs Plus Annual $8) 现在只点亮选中那个？
   - `updateMultiProviderMenu` 不再 hardcoded pay-as-you-go list
   - `providerQuotaOrder` 里没 `.geminiCLI`

### Phase 4: 工作树清理决策

跟用户确认三件事再决定:
1. `AppDelegate.swift` (B39/B40 observability, 上次 session 遗留) — 现在 session 已修 B41，需要这部分 observability 吗？
2. `Info.plist` (auto-bumped) — 直接 restore 还是 commit
3. `docs/handoffs/2026-07-05-token-king-icon-blurry.md` — 留作记录还是删

## 关键 commit hash 速查表
```
c80d2ac: 上次 session HEAD (B41 修完的 base)
e75bace: A - B32/B05/B30/B18
964df1e: D - B04/B33
7e5f89a: D - docs sync
a5ef78b: B - B22
6059b33: C - B21/B25/B26/B28/B29
dda78b1: C - merge A 进 C
26cba60: docs B19/B22/B27 backfill
c26d2ad: merge D
d05df52: merge A
abc6e14: merge C
bcbdba8: merge E
628bcaf: B21/B25/B26/B28/B29 docs backfill (latest)
```

## 不该做的
- **不要 commit** working tree 残留的 3 个文件（.gitignore / AppDelegate / Info.plist）— 用户规则
- **不要 force push**
- **不要** rebase main (会破坏 5 个 worktree 的 merge commits)
- **不要** 自动删 worktree (已通过 main 删了，但 git log 还在)

## 期望产出
写一个 `docs/handoffs/2026-07-06-p0-audit-report.md` 记录:
1. 每个 bug 的实际验证结果（pass/fail/concern）
2. 发现的问题或疑虑
3. 建议 (commit, 修, 还是 follow-up)
4. 总体验证: 5 个 agent 的改动实际是什么，对用户预期 (1,330 之谜、菜单、dead code) 的影响

## 工具
- git worktree 已清理（5 个分支已删）
- 当前 main worktree: `/Users/simengyu/projects/usage-deck/`
- 测试 build dir: `/tmp/tk-derived/`
- 上一份 handoff 笔记: `/Users/simengyu/projects/usage-deck/docs/handoffs/2026-07-05-token-king-icon-blurry.md` (关于 B41 的调查笔记，可参考但无关)
