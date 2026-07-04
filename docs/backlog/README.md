# Token King 需求库（总入口）

> 想法沉淀 + 排序的地方。成熟的需求/bug 走 `docs/superpowers/` 做 spec→plan→实现。
> backlog 只管"要做什么+优先级"，superpowers 管"怎么落地"。

## 分库

- **需求库** → [features/](features/README.md)：新功能、增强
- **Bug 库** → [bugs/](bugs/README.md)：已知缺陷

## 全局状态一览

### 需求（features/）
| ID | 标题 | 状态 | 优先级 |
|----|------|------|--------|
| F01 | Kimi 总用量显示 | 想法 | 高 |
| F02 | OpenCode Zen 单价精确换算 | 想法 | 低 |
| F03 | 货币默认选人民币 | 想法 | 中 |
| F04 | 国内/海外版订阅套餐按 region 显示 | 实现中 | 高 |
| F05 | 模型订阅套餐资料库 | 实现中 | 高 |

### Bug（bugs/）
| ID | 现象 | 状态 |
|----|------|------|
| B01 | 金额/货币显示异常 | ✅已修 |
| B02 | Provider wiring 遗漏 | ✅已修 |
| B03 | usagePercentCandidates 重复 case | ✅已修 |
| B04 | 图标映射错误/缺失 | ✅已修 |
| B05 | 国服 provider region 默认值错误 | ✅已修 |
| B06 | MiniMax 旧档位不兼容 | ✅已修 |
| B07 | 测试污染/Flaky tests | ✅已修（多管齐下） |
| B08 | StatusBarControllerTests 未清理共享状态 | ✅已修（testMode init） |
| B09 | StatusBarController init 硬编码 UserDefaults | ✅已修 |
| B10 | ProviderResultTests addTeardownBlock 模式 | ✅已修（formatter 注入） |
| B11 | ProviderRegionTests 创建 StatusBarController | ✅已修（testMode init） |
| B12 | SubscriptionSettingsManager 单例写 .standard | ✅已修（userDefaults 注入） |
| B13 | BraveSearchProviderTests 未保留原始 UserDefaults | ✅已修（snapshot save/restore） |
| B14 | ProviderUsageTests 使用 .shared SubscriptionSettingsManager | ✅已修（subscription 部分） |
| B15 | Provider 测试使用 .shared tokenManager/session | ✅已修（XDG + auth.json mock） |
| B31 | ProviderRegionTests 未覆盖新国服 provider region | ✅已修 |
| B35 | Kimi CN provider 无 legacy global key fallback | ✅已修 |
| B36 | MiniMax 重置时间显示固定窗口而非 Dashboard 滑动 | ✅已修 |
| B37 | Kimi CN fallback 后出现重复 Kimi 入口 | ✅已修 |
| B38 | 「无」与 API 检测到的套餐同时 .on | ✅已修 |

## 状态定义
- **想法**：一句话毛想法，还没细化
- **已诊断待修**：根因清楚，等修
- **细化中/设计中**：走 superpowers brainstorm/spec
- **实现中**：M3 执行 or Claude 实现
- **验收中**：等真机/测试确认
- **✅已修/已完成** → 归档
