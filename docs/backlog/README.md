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
| B02 | Provider wiring 遗漏 | 已诊断待修 |
| B03 | usagePercentCandidates 重复 case | 已诊断待修 |
| B04 | 图标映射错误/缺失 | 已诊断待修 |
| B05 | 国服 provider region 默认值错误 | 已诊断待修 |
| B06 | MiniMax 旧档位不兼容 | 已诊断待修 |
| B07 | 测试污染/Flaky tests | 已诊断待修 |

## 状态定义
- **想法**：一句话毛想法，还没细化
- **已诊断待修**：根因清楚，等修
- **细化中/设计中**：走 superpowers brainstorm/spec
- **实现中**：M3 执行 or Claude 实现
- **验收中**：等真机/测试确认
- **✅已修/已完成** → 归档
