# Bug 库

> 流转: 发现 → 已诊断待修 → 修复中 → 验收中 → ✅已修
> 会话级 TaskCreate 是临时的，这里是持久台账。

| ID | 现象 | 状态 | 根因(已诊断) | 修法 |
|----|------|------|-------------|------|
| B01 | 金额/货币显示变美元 | ✅已修 | `ProviderRegionTests` 把 `currency.selected` 写成 USD 的测试污染 | commit `7d1363c` 恢复 currency；但仍需根治测试初始化 |
| B02 | Provider wiring 遗漏 | 已诊断待修 | `ProviderManager` 漏注册 `OpenCodeProvider`；`CLIProviderManager` 漏 `.openCode`/`.tavilySearch`/`.braveSearch`；`ProviderMenuBuilder` 对多个 provider 走 default | 补注册、补 switch case、补 configInfo |
| B03 | `usagePercentCandidates` 重复 case | 已诊断待修 | `StatusBarController.usagePercentCandidates` 中 `.volcanoArk` 与 `.mimo`/`.hunyuan`/`.zhipuGLM` 有重复分支 | 去重/合并 |
| B04 | 图标映射错误/缺失 | 已诊断待修 | `ModernStatusBarIconView` 和 `MultiProviderStatusBarIconView` 里 `.zhipuGLM` 仍用 `g.circle`；`.minimaxCodingPlanCN` 在 Modern 未处理 | 换 `z.circle`；补 MiniMax CN 图标 |
| B05 | 国服 provider region 默认值错误 | 已诊断待修 | `.mimo`、`.volcanoArk`、`.hunyuan`、`.zhipuGLM` 是国服 provider，但 `region` 默认 `.global` | 默认值改为 `.china` |
| B06 | MiniMax 旧档位不兼容 | 已诊断待修 | 档位从 Starter/Plus HS/Max HS/Ultra HS 改成 Plus/Max/Ultra 后，老用户存储的旧档位菜单里不可再选 | 迁移旧档位名或做 fallback |
| B07 | 测试污染/Flaky tests | 已诊断待修 | `ProviderResultTests` 用 `UserDefaults.standard` 且只通过 `addTeardownBlock` 恢复，有次 flaky；多个测试在 `StatusBarController()` init 时触发 UserDefaults 写入 | 用独立 UserDefaults suite 或严格 teardown |
| B08 | StatusBarControllerTests 未清理共享状态 | 已诊断待修 | 测试直接 `UserDefaults.standard.set(true, forKey: "githubStarPromptDismissed")` 且从不恢复；每个用例都新建 `StatusBarController()`，其 init 会向 `UserDefaults.standard` 写入 `braveRefreshMode` 默认值、启动 timer/background task | 使用独立 UserDefaults suite 或在 setUp/tearDown 中保存/恢复相关 key；测试用 StatusBarController 应提供可注入 defaults 的初始化或禁用后台任务 |
| B09 | StatusBarController init 硬编码 UserDefaults.standard 且启动后台任务 | 已诊断待修 | `StatusBarController.init()` 直接读写 `UserDefaults.standard`（refreshInterval/predictionPeriod/displayMode/braveRefreshMode/githubStarPrompt 等），并调用 `CurrencyFormatter.shared.refreshRateInBackground()` 和 `startRefreshTimer()` | 将 UserDefaults、formatter、timer 改为可注入；提供测试用初始化子关闭后台任务 |
| B10 | ProviderResultTests 使用 UserDefaults.standard 且依赖 addTeardownBlock | 已诊断待修 | 测试直接读写 `UserDefaults.standard` 的 currency/rate key，通过 `addTeardownBlock` 恢复；崩溃或提前退出时恢复不执行；同时污染共享 `CurrencyFormatter`/`ExchangeRateStore` | 改用独立 `UserDefaults(suiteName:)` 注入 `CurrencyFormatter` 和 `ExchangeRateStore` |
| B11 | ProviderRegionTests 修改 CurrencyFormatter.shared 并创建 StatusBarController | 已诊断待修 | 测试用 `defer` 恢复 `CurrencyFormatter.shared.currency`，但创建 `StatusBarController()` 会触发 UserDefaults 写入和后台任务；`defer` 在崩溃时不保证执行 | 注入独立 formatter/defaults；避免在区域测试中初始化完整 status bar controller |
| B12 | SubscriptionSettingsManager 单例写 UserDefaults.standard | 已诊断待修 | `SubscriptionSettingsManager.shared` 直接读写 `UserDefaults.standard`；`ProviderRegionTests` 和 `ProviderUsageTests` 向其写入 subscription_v2.* 数据，仅对特定 key defer 清理 | 给 SubscriptionSettingsManager 增加 `UserDefaults` 注入初始化；测试使用独立 suite |
| B13 | BraveSearchProviderTests 未保留原始 UserDefaults | 已诊断待修 | setUp/tearDown 只 `removeObject` Brave 相关 key，不保存/恢复用户原有值；多个测试并行时互相覆盖 | setUp 保存原值，tearDown 恢复；或改用注入的 UserDefaults |
| B14 | ProviderUsageTests 读取 ProviderManager.shared 与 SubscriptionSettingsManager.shared | 已诊断待修 | `testProviderManagerDefaultProvidersExcludeKiro` 使用 `ProviderManager.shared` 单例；subscription 测试使用 `SubscriptionSettingsManager.shared`，未重置缓存 | 使用自定义 `ProviderManager(providers:)` 注入；SubscriptionSettingsManager 注入独立 defaults |
| B15 | 多个 Provider 测试使用 .shared tokenManager/session | 已诊断待修 | `VolcanoArkProviderTests`、`MiniMaxProviderTests`、`KimiProviderTests` 部分用例传入 `tokenManager: .shared` / `session: .shared`，依赖全局状态和真实网络 | 全部使用 mock tokenManager 和 `MockURLProtocol` 注入 session |
| B16 | CLIProviderManager 注册列表与实例数组不一致 | 已诊断待修 | `CLIProviderManager.registeredProviders` 包含 `.tavilySearch`/`.braveSearch`，但 `init` 的 `providers` 数组未实例化对应 Provider；`.openCode` 既未出现在 `registeredProviders` 也未实例化 | 在 `providers` 数组追加 `TavilySearchProvider()`、`BraveSearchProvider()`；在 `registeredProviders` 与 `providers` 中补 `.openCode`/`OpenCodeProvider()`，并与 ProviderManager 保持一致 |
| B17 | ProviderMenuBuilder 对 openCode/tavilySearch/braveSearch 走 default | 已诊断待修 | `createDetailSubmenu` 的 switch 缺少 `.openCode`、`.tavilySearch`、`.braveSearch` 分支，导致 detail 子菜单只有通用 trailing 行 | 补这三个 provider 的专属 case：openCode 显示额度/用量；搜索 provider 复用 `createSearchEngineRows` 或显示用量/错误 |
| B18 | ModernStatusBarIconView 图标映射与 ProviderProtocol 不一致 | 已诊断待修 | `.zhipuGLM` 仍用 `g.circle`（ProviderProtocol 已改为 `z.circle`）；`.minimaxCodingPlanCN` 未处理；`.geminiCLI` 使用 `sparkles` 与 ProviderProtocol 的 `g.circle` 不一致 | 统一优先读取 `identifier.iconName` 或显式同步所有 case；补 `.minimaxCodingPlanCN`；zhipuGLM 改 `z.circle` |
| B19 | ProviderMenuBuilder 中 synthetic/kiro 出现重复分隔线 | 已诊断待修 | `.synthetic`、`.kiro` 的 case 在调用 `addSubscriptionItems` 前手动 add separator，而 `addSubscriptionItems` 内部又 add separator | 移除 `.synthetic`、`.kiro` case 中多余的 `submenu.addItem(NSMenuItem.separator())` |
| B20 | StatusBarController.configInfo 多个 provider 走 default | 已诊断待修 | `configInfo(for:)` switch 对 `.tavilySearch`、`.braveSearch`、`.geminiCLI`、`.cursor`、`.commandCode`、`.kiro` 等使用 default 提示 "对应 provider 的 key 字段" | 补全缺失 provider 的配置字段名与路径，保持与 TokenManager key 读取逻辑一致 |
| B21 | 启用 Gemini CLI 多账户时 quota 菜单出现重复条目 | 已诊断待修 | `.geminiCLI` 同时出现在 `providerQuotaOrder` 与 `updateMultiProviderMenu` 后的专门处理块中；循环按 aggregate usage 插入一行，后续块又为每个 `geminiAccount` 插入一行 | 从 `providerQuotaOrder` 移除 `.geminiCLI`，或在循环中跳过 Gemini（保留专门的 per-account 块） |
| B22 | 同名订阅套餐被同时高亮 | 已诊断待修 | `ProviderMenuBuilder.addSubscriptionItems` 通过 `selectedName == preset.name` 判断选中，未比较 cost；Gemini CLI 有两个 Plus（$4/$8）、两个 Ultra（$125/$250） | 选中判断同时比较 name 与 cost，或改用 `item.representedObject` 中的 plan 匹配 |
| B23 | CLI 与 App 对 `.kiro` 启用策略不一致 | 已诊断待修 | `ProviderIdentifier.kiro.isEnabled == false`，`ProviderManager` 过滤掉；`CLIProviderManager.registeredProviders` 与 providers 数组仍包含 `.kiro` | 统一启用/禁用策略：若 App 不启用，CLI 也不应注册；或明确注释说明差异 |
| B24 | 搜索引擎「点击配置」提示信息无意义 | 已诊断待修 | `StatusBarController.configInfo(for:)` 对 `.tavilySearch`/`.braveSearch` 走 default，返回「对应 provider 的 key 字段」与通用路径 | 补 `.tavilySearch`、`.braveSearch` 的 fieldName 与配置路径 |
| B25 | 按量付费区写死仅 .openRouter/.openCodeZen | 已诊断待修 | `updateMultiProviderMenu` 与分享快照均硬编码 pay-as-you-go provider 顺序；即使 `.openCode` 等被启用也不会出现 | 按 `ProviderType.payAsYouGo` 与启用状态动态收集 providers |
| B26 | 预测周期菜单状态与实际显示不同步 | 已诊断待修 | `setupMenu` 创建并保存 `predictionPeriodMenu`，但该菜单从未挂到可见菜单；`updatePredictionPeriodMenu()` 只更新这个隐藏菜单 | 移除属性，或让可见的预测周期子菜单复用/同步该菜单状态 |
| B27 | 订阅菜单「该版本仅海外」提示不可达 | 已诊断待修 | `addSubscriptionItems` 中 `visiblePresets.isEmpty` 仅在 `hasCNYPresets && 无 cnyCost` 时成立，而 `hasCNYPresets` 定义即为存在 cnyCost，逻辑互斥 | 删除该死代码分支 |
| B28 | 用量历史菜单项已创建但从未加入主菜单 | 已诊断待修 | `setupMenu` 中初始化 `historyMenuItem`/`historySubmenu` 后，`menu.addItem(historyMenuItem)` 被注释掉 | 移除死属性，或确认是否需要恢复历史入口 |
| B29 | 动态菜单项使用 magic number `999` 作为 tag | 已诊断待修 | `updateMultiProviderMenu` 用 `tag == 999` 识别并清理动态插入的项，无命名常量 | 定义 `private enum MenuItemTag { static let dynamic = 999 }` 等命名常量 |
| B30 | Gemini CLI 订阅档位出现重复名称 | 已诊断待修 | `ProviderSubscriptionPresets.geminiCLI` 里 "Plus"/"Ultra" 各出现两次不同价格 | 重命名档位或删除重复项，使菜单名称唯一 |
| B31 | ProviderRegionTests 未覆盖新国服 provider 的 region 默认值 | 已诊断待修 | 测试只断言 `.kimiCN`/`.minimaxCodingPlanCN` 为 `.china`，未覆盖 `.mimo`/`.volcanoArk`/`.hunyuan`/`.zhipuGLM` | 补充 region 断言（应为 `.china`），作为 B05 回归测试 |
| B32 | 国内 provider USD 订阅价使用固定汇率 7.2 | 已诊断待修 | `volcanoArk`/`hunyuan`/`zhipuGLM` 的 cost 用 `1.0/7.2` 硬编码，而 `CurrencyFormatter` 使用实时汇率 | USD 模式下用 `cnyCost / formatter.currentRate` 计算，或以 CNY 为唯一真值统一换算 |
| B33 | 死代码状态栏视图硬编码 "$" | 已诊断待修 | `ModernStatusBarIconView` / `MultiProviderStatusBarIconView` 多 provider 分支写死 `$`，与货币设置不一致 | 删除死代码或接入 `CurrencyFormatter` |
| B34 | MiMo 订阅预设注释与国服定位矛盾 | 已诊断待修 | 注释写 "仅海外 Token Plan"，但 MiMo 被归为国服且预设含 `cnyCost` | 修正注释，必要时按 region 拆分 preset catalog |
