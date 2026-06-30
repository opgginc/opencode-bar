# Token King — opencode-bar Fork 定制设计

> 状态：设计已获用户逐节确认（2026-06-30）。本 spec 覆盖全部 5 阶段设计；实施计划（writing-plans）先详细展开阶段 0 + 阶段 1。

## 1. 项目定位

Fork 开源项目 `opgginc/opencode-bar`（macOS 菜单栏 AI 用量监控，MIT，281★），改造成个人定制版 **Token King**。

双重目的：
1. **能用** — 监控多个 AI provider 的用量，绕开之前自研 widget 撞的所有坑（opencode-bar 已解决多 provider 聚合 + 非沙盒菜单栏形态）。
2. **练手** — 作为学习 Swift / macOS 工程的载体。fork 成熟项目改 = 读"别人被痛过之后的答案卷"，比从 0 写学得快。

工作区：`~/projects/usage-deck/`（已 clone，origin 已改名 upstream）。

## 2. 基底为什么好（练手价值点）

| 设计 | 作用（大白话） | 对应练手目标 |
|---|---|---|
| Provider 协议 | "查用量"的统一抽象——不管从 HTTP/命令/文件拿数，都吐出统一 `ProviderUsage`(剩余/上限/重置) | 目标2 加引擎照模板填空 |
| actor 并发 | Swift `actor` 强制数据访问排队，并发查多 provider 不串台，无需手动加锁 | 目标2 多 key 并发查 |
| MenuDesignToken | 用代码常量强制执行的设计规范（只能引用，改一处全局生效），非文档 | 目标2/3/5 改 UI |
| reflection 踩坑记录 | 作者踩坑日记写进 AGENTS.md 跟代码走 git | 全程参考 |

## 3. 五个目标与改造点

### 阶段 0 — Fork 治理（地基）
- 建 GitHub fork，本地双 remote：`upstream`（原作者，拉更新）/ `origin`（用户 fork，push 改动）
- 改 bundle ID → `com.tokenking.app`；app 显示名 → `Token King`
- 改写 `AGENTS.md` 加「定制分支声明」，解除上游三条硬规则锁（UI 必英文 / 只 USD / 品牌锁死 `OpenCode Bar`），声明本分支为学习用个人定制、规则以用户需求为准（允许中文、RMB、改品牌）
- `README` 注明 fork 自 opencode-bar、MIT、学习用途、保留原作者署名
- **验收**：能编译、能跑、与 brew 装的官方版并存不冲突（bundle ID 已不同）

### 阶段 1 — 多 Key + 多搜索引擎（练手核心）
- **多 tavily key**：现 `getTavilyAPIKeyWithSource()` 只取 1 个 → 改成读全部 key 循环查，菜单显示成多账号。**抄 `GeminiCLIProvider` 的多账号模式**（`candidates[]` + dedup + map）
- **Key 数据源（接法2）**：token-king 内部定义 `KeySource` 抽象（协议）。第一版实现 = 直接读 ai-infra 的 `~/projects/ai-infra/.private/resources/keys.local.yaml`（用户所有 key 的权威源，tavily 下有 apple/github/google/qq 4 个）。将来 ai-infra 提供 `keys export` 导出命令后，换 `KeySource` 实现即可，耦合隔离在一个模块内
- **anysearch**：新建 `AnySearchProvider`，照 Provider 协议填空（先查 anysearch 有无用量 API）
- **验收**：菜单里 tavily 显示 4 个 key 各自用量；anysearch 显示出来

### 阶段 2 — 货币 + 菜单栏精简（显示层）
- **货币**：新建 `CurrencyFormatter`（管汇率 + 格式化），替换散落的 `String(format: "$%.2f")`（主要在 `ProviderMenuBuilder`）；支持 USD/RMB
- **汇率（方案 C：本地默认 + 拉取回写）**：本地存一个默认汇率值；启动尝试拉实时汇率，**拉取成功就回写本地缓存**，失败则用本地最近一次的值（stale-while-revalidate 模式）。即使长期离线也是最近一次真实汇率而非死常量
- **菜单栏精简**：加配置开关，控制显示/隐藏哪些 provider、哪些字段
- **验收**：能切人民币显示；能隐藏不用的 provider

### 阶段 3 — 中文化（量大机械）
- 接入 String Catalog（`.xcstrings`），把全部 user-facing 英文抽出来译中文（app 当前**零 i18n**，无 NSLocalizedString / .strings）
- **验收**：菜单全中文

### 阶段 4 — Widget 显示（最难，留最后）
- 新建 WidgetKit target，**抄 TokenEater 的 home-relative-path 方案**（已查清的沙盒墙正解，免费账号可行）
- 主 app 加：把用量导出成 JSON 到固定路径 `~/Library/Application Support/com.tokenking.app.shared/usage.json`
- widget entitlement 加 `temporary-exception.files.home-relative-path.read-only` 读该路径；用 `getpwuid(getuid()).pw_dir` 取真实 home（沙盒里 NSHomeDirectory 返容器路径）
- **先做最小验证**：免费 ad-hoc 签名认不认 temporary-exception entitlement（widget 读一次文件看 Console 有无 sandbox deny）
- 不认则切兜底：localhost HTTP（widget 加 `network.client`，主 app 起本地 server）
- **验收**：桌面 widget 显示用量

## 4. 与上游同步策略

- 改动尽量**新增文件**（AnySearchProvider / CurrencyFormatter / KeySource 都是新文件），与上游冲突最小
- 必须改原文件处（TavilyProvider 多 key、AGENTS.md）集中、可控
- 定期 `git fetch upstream` 看更新，按需 merge（如上游发带 Kiro 的 release）
- 每个阶段用 feature branch（如 `feat/multi-tavily-key`），不在 main 上乱改

## 5. 交付节奏

- 每阶段 = 独立可交付、可验证的里程碑，做完 commit + fork 上能跑起来看效果，再进下一个
- 顺序：阶段 0 → 1 → 2 → 3 → 4（widget 最难、平台特定、可迁移性低，故最后）
- **实施计划先详细展开阶段 0 + 1**；后续阶段做完前两个、摸熟 codebase 后再细化，避免纸上谈兵

## 6. 已确认的决策记录

| 决策 | 结论 |
|---|---|
| 品牌名 | `token-king`（显示名 Token King，bundle ID `com.tokenking.app`） |
| 阶段顺序 | 0→1→2→3→4，widget 优先方案已否决 |
| fork 管理 | push 到用户自己 GitHub fork，注明学习用途 |
| 多 key 数据源 | ai-infra `keys.local.yaml`（接法2：KeySource 抽象隔离，先读文件，后接导出命令） |
| 汇率 | 方案 C：本地默认 + 拉取成功回写缓存 |
| 本次实施范围 | 计划先展开阶段 0 + 1 |

## 7. 参考

- 上游：github.com/opgginc/opencode-bar（MIT）
- widget 沙盒墙正解范本：github.com/AThevon/TokenEater
- 沙盒墙调研结论：`~/.claude/projects/-Users-simengyu/memory/参考/widget沙盒墙真相.md`

## 8. 残留项 / 已查证结论

- **anysearch 无用量 API（2026-07-01 查证，搁置）**：anysearch 是 MCP 服务（`https://api.anysearch.com/mcp`），只暴露 4 个搜索工具（`batch_search` / `extract` / `get_sub_domains` / `search`），无任何用量/余额/配额接口。REST 端点（`/usage` `/account` `/balance` `/quota` 等）全部 404，MCP `resources/list` 返回 "resources not supported"。结论：与 mimo 同类，无可读用量数据源，**不纳入 widget**。待 anysearch 未来提供用量 API 再实现 `AnySearchProvider`。
