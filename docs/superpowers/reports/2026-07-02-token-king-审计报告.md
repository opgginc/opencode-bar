# Token King 菜单/货币优化 + Provider 国内/海外分离 — 审计报告

**报告时间**：2026-07-02  
**提交范围**：`main` 最近 5 个 commit  
**审计目标**：整理完整变更，供 Claude 审计并规划下一步  
**验证状态**：✅ 全量测试通过（264 tests, 22 skipped, 0 failures）；✅ CLI target 编译通过；✅ Release 构建并安装至 `/Applications/Token King.app`

---

## 1. 执行摘要

本次变更包含两条主线：

1. **菜单/货币优化计划**（前 3 个 commit）：修复原计划中 3 个会导致编译失败或金额翻倍的缺陷，完成人民币化、顶层菜单精简、Kimi 档位定价、尚未配置折叠。
2. **Provider 国内/海外分离重构**（后 2 个 commit）：按「国内优先 + 国内/海外彻底分离」原则拆分 MiniMax/Kimi，补齐 RMB 隐藏纯海外档、Kimi level 映射、测试覆盖。

两条线均已跑通全量测试并发布安装。

---

## 2. 变更详情

### 2.1 菜单/货币优化

#### commit `2c599c6` — Kimi 国内档位定价
- **文件**：`Models/SubscriptionSettings.swift`、`CopilotMonitorTests/SubscriptionPresetTests.swift`
- **内容**：
  - Kimi 预设调整为 Andante(¥49)/Moderato($19, ¥99)/Allegretto($39, ¥199)/Allegro($99, ¥699)/Vivace($199, 无 CNY)。
  - Andante 作为纯国内档，`cost = 0` 并加注释说明无官方海外价，不拿估算值冒充。
  - 更新 `SubscriptionPresetTests` 断言。

#### commit `8760b96` — 订阅总额人民币化
- **文件**：`Models/SubscriptionSettings.swift`、`Helpers/ProviderMenuBuilder.swift`、`App/StatusBarController.swift`、`Providers/CommandCodeProvider.swift`
- **内容**：
  - 修正原计划 3 个缺陷：
    - 缺陷1：通过 `providerIdentifier(for:)` + `presets(for:)` 反查 `cnyCost`；custom 档按汇率兜底。
    - 缺陷2/3：新增 `SubscriptionSettingsManager.totalMonthlyCostDisplayText(currency:formatter:)`，把「求和+货币选择+格式化」内聚，不再外部访问 `rateStore`，避免 `format(usd:)` 二次转换翻倍。
  - `SubscriptionPreset.formattedPrice(decimals:)`：RMB 且有 `cnyCost` 时显示 `¥Int(cny)`，否则回退 `format(usd:)`。
  - ProviderMenuBuilder 档位 suffix 改为 `/月`。
  - `CommandCodeProvider.usageSummary` 数据层去掉 `$`，格式化留到渲染层。

#### commit `bba9819` — 顶层菜单精简 + 尚未配置折叠
- **文件**：`App/StatusBarController.swift`、`CopilotMonitorTests/StatusBarControllerTests.swift`
- **内容**：
  - `setupMenu()` 新增「设置」子菜单（gearshape），将检查更新/自动刷新/状态栏选项/开机启动/安装CLI/分享快照/版本/退出/查看错误详情 移入。
  - 保留第一条分隔线作为 `updateMultiProviderMenu` 动态区锚点。
  - 错误详情等状态刷新 item 改为类存储属性强引用，避免移入 submenu 后失效。
  - 设置菜单在有真错误时显示红点角标。
  - 新增 `createUnconfiguredProvidersSubmenu`（tag=999），`.noCredentials` provider 折叠进「尚未配置」；`.noSubscription` 保留原处。
  - 测试：初始化后顶层非分隔项 == `["刷新", "设置"]`。

### 2.2 Provider 国内/海外分离

#### commit `acf148c` — Provider 拆分 + RMB 隐藏 + Kimi level 映射
- **文件**：
  - 新增：`Providers/KimiCNProvider.swift`、`KimiGlobalProvider.swift`、`KimiUsageTypes.swift`、`MiniMaxCNProvider.swift`、`MiniMaxGlobalProvider.swift`、`MiniMaxCodingPlanTypes.swift`
  - 删除：`Providers/KimiProvider.swift`、`MiniMaxProvider.swift`
  - 修改：`Models/ProviderProtocol.swift`、`Services/TokenManager.swift`、`Services/ProviderManager.swift`、`CLI/CLIProviderManager.swift`、`Models/SubscriptionSettings.swift`、`Helpers/ProviderMenuBuilder.swift`、`Providers/CommandCodeProvider.swift`、视图文件、测试文件
- **内容**：
  - **阶段 0**：已完成 provider 分区调研报告 `docs/superpowers/reports/2026-07-02-provider-region-audit.md`。
    - MiniMax 有独立国内/海外端点；Kimi 无独立国内端点，按 key/region 区分。
  - **阶段 1**：
    - `ProviderIdentifier` 增加 `.kimiCN` / `.minimaxCodingPlanCN`。
    - MiniMax 拆为 `MiniMaxCNProvider`（`api.minimaxi.com`）和 `MiniMaxGlobalProvider`（`api.minimax.io`）。
    - Kimi 拆为 `KimiCNProvider` / `KimiGlobalProvider`（共用 `api.kimi.com`，独立 key 字段 `kimi-for-coding-cn` / `kimi-for-coding`）。
    - `TokenManager` 增加对应 key 读取；`ProviderManager`/`CLIProviderManager` 国内版排海外版前。
    - `SubscriptionSettings.presets(for:)` 为国内版提供原生 CNY 价，海外版仅 USD。
    - 保留旧枚举 `.kimi` / `.minimaxCodingPlan` 作为全球版别名，避免丢配置。
  - **阶段 2**：`ProviderMenuBuilder.addSubscriptionItems` 在 RMB 模式下过滤掉无 `cnyCost` 的档位；全部无 CNY 时显示「该版本仅海外」。
  - **阶段 3**：`SubscriptionPlan.displayName/shortDisplayName` 去硬编码 `$`/`/m`；`CommandCodeProvider` 数据层去 `$`。
  - **阶段 4**：新增 `KimiPlanMapper`，将 `LEVEL_INTERMEDIATE` 映射为 `Moderato`（已用真实账号验证，limit=100, region=CN）；`LEVEL_VIVACE` 映射为 `Vivace`；未知 level 保持旧行为。`addSubscriptionItems` 支持 `detectedPlanName`，用户未手动选择时自动高亮 API 检测到的档位。

#### commit `3428398` — Phase 5 测试补齐
- **文件**：`CopilotMonitorTests/ProviderRegionTests.swift`、`App/StatusBarController.swift`、`CopilotMonitor.xcodeproj/project.pbxproj`
- **内容**：
  - 新增 `ProviderRegionTests`：
    - StatusBarController 动态菜单顺序：KimiCN 在 KimiGlobal 前，MiniMaxCN 在 MiniMaxGlobal 前。
    - RMB 模式隐藏 Kimi Vivace、所有 MiniMax Global 档位。
    - RMB 模式展示全部 MiniMax CN 档位并显示原生 CNY。
    - 迁移不丢配置：旧的 `.minimaxCodingPlan` / `.kimi` 订阅 key 仍可读写。
  - 将 `StatusBarController.quotaOrder` 提取为 `static let providerQuotaOrder`，并修正 Kimi 顺序为国内优先。

---

## 3. 验证结果

| 验证项 | 命令/方式 | 结果 |
|---|---|---|
| 全量测试 | `xcodebuild test -scheme CopilotMonitor -destination 'platform=macOS'` | **264 passed, 22 skipped, 0 failed** |
| CLI target 编译 | `xcodebuild build -scheme opencodebar-cli -destination 'platform=macOS'` | **BUILD SUCCEEDED** |
| Release 构建安装 | `make release` | 成功安装到 `/Applications/Token King.app` |
| 启动验收 | `open "/Applications/Token King.app"` | 进程正常启动，网络请求 200，无崩溃 |

---

## 4. 已知风险与待确认事项

### 4.1 Kimi level 映射不全
- 当前仅验证 `LEVEL_INTERMEDIATE → Moderato`（真实账号）和 `LEVEL_VIVACE → Vivace`（测试夹具）。
- 其他 level（如 `LEVEL_BEGINNER`/`LEVEL_ADVANCED`/`LEVEL_EXPERT` 等）映射待真实账号响应确认，代码中已标注「待补」并回退到旧行为。
- **建议**：后续拿到不同档位 Kimi 账号后，补全 `KimiPlanMapper` 映射表。

### 4.2 Kimi 国内/海外拆分的现实冲突
- Kimi 没有独立国内 base URL，两个 provider 实际都请求 `api.kimi.com`，只是 key 字段不同。
- 国内用户大多只有 `kimi-for-coding` 一个 key，拆分后需用户手动添加 `kimi-for-coding-cn` 才能启用 Kimi CN provider。
- **建议**：在 UI 或文档中说明：Kimi CN/Global 共用端点，区别在于 auth key。

### 4.3 旧 MiniMax provider 迁移
- 旧 `.minimaxCodingPlan` 保留为全球版别名，用户已选套餐不会丢。
- 但旧版 `MiniMaxProvider` 的「双端点 fallback」行为已彻底移除；如果用户此前依赖一个 key 同时探测国内/海外，现在需要分别配置两个 key。

### 4.4 RMB 模式纯海外档
- 当前仅隐藏无 `cnyCost` 的 preset，不阻止用户选自定义金额。
- Vivace 在 USD 模式下仍正常显示。

---

## 5. 下一步建议

1. **补全 Kimi level 映射**：用更多真实账号抓取 `membership.level`，补全 `KimiUsageTypes.swift` 中的映射表。
2. **真机菜单验收**：人工确认顶层菜单只剩「刷新/设置/用量区/尚未配置」、货币切换对订阅总额和各档位生效、无翻倍、Kimi 档位显示正确。
3. **文档更新**：在 README 或用户文档中说明 Kimi/MiniMax 国内/海外 provider 的配置方式。
4. **回归观察**：发布后观察 1-2 个更新周期，确认无配置丢失、无菜单错位。

---

## 6. 审计关注点（供 Claude 重点看）

1. `SubscriptionSettingsManager.totalMonthlyCostDisplayText` 是否正确内聚了货币判断，避免外部再次转换？
2. `ProviderMenuBuilder.addSubscriptionItems` 的 `detectedPlanName` 自动高亮逻辑是否会覆盖用户手动选择？
3. `StatusBarController.providerQuotaOrder` 是否在所有需要 provider 顺序的地方被一致使用？
4. `KimiPlanMapper` 的 fallback 行为对未知 level 是否足够安全？
5. pbxproj 中新增文件（`KimiPlanMapperTests.swift`、`ProviderRegionTests.swift`）是否已在 app 和 CLI target 正确注册？

---

## 7. 提交清单

```
3428398 test(provider): Phase 5 regression tests for CN/Global split and RMB hiding
acf148c refactor(provider): split MiniMax/Kimi into CN/Global providers, RMB-hide overseas tiers, add Kimi level mapping
8760b96 fix(currency): localize subscription totals to RMB with native CNY pricing
2c599c6 fix(kimi): update domestic presets with Andante/Allegro and native CNY prices
bba9819 refactor(menu): fold unconfigured providers into '尚未配置' submenu
```

---

**结论**：本次两条主线变更已完成并发布。代码层面测试覆盖充分，但 Kimi level 映射和真机 UI 验收仍有待补充。建议按第 5 节推进。
