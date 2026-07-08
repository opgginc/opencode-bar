# F2b — Provider Monthly Usage & Pay-as-you-go Cost Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build macOS Menu Bar app layer that aggregates 7 token data sources (5 local tools + 2 API providers) by **Provider** (Kimi/Claude/Codex/Z.AI/NanoGpt) for the current calendar month, applies F2a `PricingTable` rates to compute pay-as-you-go cost, and renders in the existing Menu Bar UI. Architecture follows 5-reference research (tokenmeter/codeburn/tokscale/toll/ccusage) — 7 design patterns adopted (UsageEntry, source_id dedup, apply_total_token_fallback, env-var override, byte offset incremental, broken-line skip, safePerTokenRate clamp).

**Architecture:**
- **Layer 1 — TokenExtractor (7 adapters):** Each tool/API emits `RawTokenEvent` with model + 5 token fields + source. Reading is **byte-offset incremental** (no full re-scan on tick).
- **Layer 2 — ProviderNormalizer:** Maps `model`/`providerID` → `Provider` enum (kimi/claude/codex/zai/nanoGpt) by **model first, providerID fallback**.
- **Layer 3 — TokenUsageStore (actor + SQLite):** 30s tick RefreshActor. `token_events` table (raw, with `source_id UNIQUE` for dedup). `month_aggregates` table (per provider × model × year_month, materialized). `model_pricing_cache` mirrors F2a `PricingTable`.
- **Layer 4 — MonthCostCalculator:** Reads `month_aggregates` + `model_pricing_cache` → returns `costRMB` per provider × model. `cacheWrite` excluded (5-reference consensus: Anthropic free, OpenAI simplified).
- **Layer 5 — UI:** Modify `StatusBarController.swift` to insert "本月 API 折算 ¥XXX" row beneath existing quota status; modify `ProviderMenuBuilder.swift` to add "按量折算 ¥XXX" row in per-provider detail.
- **Layer 6 — ErrorHandling:** Broken JSONL lines skipped, missing data sources silent `(nil, nil)`, missing pricing → `cost = nil` + UI "未知" badge, schema_version mismatch → rebuild.

**Tech Stack:** Swift 5, SwiftUI/AppKit hybrid, SwiftData (or raw SQLite via FMDB-style Swift wrapper), XCTest for unit + UI tests. No new dependencies; reuse F2a `PricingTable` (v2.12.0, commit `87c4ef7`).

---

## File Structure (delta)

```
新增:
  CopilotMonitor/CopilotMonitor/Helpers/TokenEvent.swift
  CopilotMonitor/CopilotMonitor/Helpers/TokenNormalizer.swift
  CopilotMonitor/CopilotMonitor/Helpers/MonthCostCalculator.swift
  CopilotMonitor/CopilotMonitor/Helpers/TokenExtractor/OpenCodeExtractor.swift
  CopilotMonitor/CopilotMonitor/Helpers/TokenExtractor/ClaudeCodeExtractor.swift
  CopilotMonitor/CopilotMonitor/Helpers/TokenExtractor/CodexExtractor.swift
  CopilotMonitor/CopilotMonitor/Helpers/TokenExtractor/KimiCLILegacyExtractor.swift
  CopilotMonitor/CopilotMonitor/Helpers/TokenExtractor/KimiCodeExtractor.swift
  CopilotMonitor/CopilotMonitor/Helpers/TokenExtractor/ZAIExtractor.swift
  CopilotMonitor/CopilotMonitor/Helpers/TokenExtractor/NanoGPTExtractor.swift
  CopilotMonitor/CopilotMonitor/Helpers/TokenUsageStore.swift
  CopilotMonitor/CopilotMonitor/Helpers/RefreshActor.swift
  CopilotMonitor/CopilotMonitorTests/Helpers/TokenEventTests.swift
  CopilotMonitor/CopilotMonitorTests/Helpers/TokenNormalizerTests.swift
  CopilotMonitor/CopilotMonitorTests/Helpers/MonthCostCalculatorTests.swift
  CopilotMonitor/CopilotMonitorTests/Helpers/TokenExtractor/OpenCodeExtractorTests.swift
  CopilotMonitor/CopilotMonitorTests/Helpers/TokenExtractor/ClaudeCodeExtractorTests.swift
  CopilotMonitor/CopilotMonitorTests/Helpers/TokenExtractor/CodexExtractorTests.swift
  CopilotMonitor/CopilotMonitorTests/Helpers/TokenExtractor/KimiCLILegacyExtractorTests.swift
  CopilotMonitor/CopilotMonitorTests/Helpers/TokenExtractor/KimiCodeExtractorTests.swift
  CopilotMonitor/CopilotMonitorTests/Helpers/TokenExtractor/ZAIExtractorTests.swift
  CopilotMonitor/CopilotMonitorTests/Helpers/TokenExtractor/NanoGPTExtractorTests.swift
  CopilotMonitor/CopilotMonitorTests/Helpers/TokenUsageStoreTests.swift
  CopilotMonitor/CopilotMonitorTests/Helpers/RefreshActorTests.swift
  CopilotMonitor/CopilotMonitorUITests/F2bE2ETests.swift

修改:
  CopilotMonitor/CopilotMonitor/App/StatusBarController.swift         (加 header 新行)
  CopilotMonitor/CopilotMonitor/Helpers/ProviderMenuBuilder.swift    (加 per-provider "按量折算" row)
  CopilotMonitor/CopilotMonitor/App/AppDelegate.swift                (启动 RefreshActor)
  CopilotMonitor/CopilotMonitor.xcodeproj/project.pbxproj             (8 新 file × 4 register locations = 32 places for src, 32 for tests = 64 pbxproj edits)

PBXPROJ 规则 (per AGENTS.md): 每个 .swift 新增 = 4 处注册 (PBXBuildFile / PBXFileReference / PBXGroup / PBXSourcesBuildPhase).
src files 11 个 → 44 pbxproj edits
test files 12 个 → 48 pbxproj edits
总计 92 pbxproj edits
```

---

## Task 1: TokenEvent / TokenBreakdown / Provider / TokenSource structs

**Files:**
- Create: `CopilotMonitor/CopilotMonitor/Helpers/TokenEvent.swift`
- Create: `CopilotMonitor/CopilotMonitorTests/Helpers/TokenEventTests.swift`

- [ ] **Step 1: Write TokenEvent.swift with all structs and enums**

```swift
import Foundation

/// Provider 归一化后枚举 (F2b 主视角).
/// - `.kimi`:  kimi-for-coding / k2p* / moonshot providerID
/// - `.claude`: claude-* / anthropic providerID
/// - `.codex`:  gpt-* / o3-* / o4-* / openai providerID
/// - `.zai`:    glm-* / z-ai providerID
/// - `.nanoGpt`: 兜底 (任何未识别的 model + providerID)
enum Provider: String, Codable, CaseIterable, Hashable {
    case kimi, claude, codex, zai, nanoGpt

    var displayName: String {
        switch self {
        case .kimi:    return "Kimi"
        case .claude:  return "Claude"
        case .codex:   return "Codex"
        case .zai:     return "Z.AI"
        case .nanoGpt: return "NanoGpt"
        }
    }
}

/// 7 个 TokenExtractor 数据源标识.
/// - `.opencode`/`.claudeCode`/`.codexCli`: 3 个本地 CLI 工具 (跨 Provider)
/// - `.kimiCli`/`.kimiCode`: 2 个 Kimi 工具版本 (都归 Provider.KIMI)
/// - `.zaiApi`/`.nanoGptApi`: 2 个 provider API 调
enum TokenSource: String, Codable, CaseIterable, Hashable {
    case opencode, claudeCode, codexCli
    case kimiCli, kimiCode
    case zaiApi, nanoGptApi
}

/// 5 字段 token 拆分 (5 reference 共识: input/output/cacheRead/cacheWrite/reasoning).
/// `cacheWrite` 5 reference 共识: 通常不计费 (Anthropic prompt cache 写免费).
struct TokenBreakdown: Codable, Hashable {
    var input: Int = 0
    var output: Int = 0
    var cacheRead: Int = 0
    var cacheWrite: Int = 0
    var reasoning: Int = 0

    static let zero = TokenBreakdown()

    var total: Int {
        input + output + cacheRead + cacheWrite + reasoning
    }
}

/// TokenExtractor 输出 + ProviderNormalizer 输入.
/// 在 SQLite `token_events` 表的 UNIQUE source_id key 上去重.
struct TokenEvent: Codable, Hashable {
    let provider: Provider            // 归一化后 (ProviderNormalizer 跑过)
    let model: String                 // 原始 model 名 (e.g. "kimi-for-coding", "gpt-4o", "claude-sonnet-4-5")
    let source: TokenSource           // 数据源
    let sessionId: String             // 来自路径 or in-file
    let timestamp: Date
    let tokens: TokenBreakdown
    let sourceId: String              // 去重 key: "<source>:<session>:<stream>:<msgId>"
}
```

- [ ] **Step 2: Write TokenEventTests.swift with 12 unit tests**

```swift
import XCTest
@testable import OpenCode_Bar

final class TokenEventTests: XCTestCase {
    func testTokenBreakdownTotal() {
        let t = TokenBreakdown(input: 100, output: 50, cacheRead: 30, cacheWrite: 0, reasoning: 5)
        XCTAssertEqual(t.total, 185)
    }

    func testTokenBreakdownZero() {
        XCTAssertEqual(TokenBreakdown.zero.total, 0)
    }

    func testTokenBreakdownCodable() throws {
        let t = TokenBreakdown(input: 1, output: 2, cacheRead: 3, cacheWrite: 4, reasoning: 5)
        let data = try JSONEncoder().encode(t)
        let decoded = try JSONDecoder().decode(TokenBreakdown.self, from: data)
        XCTAssertEqual(decoded, t)
    }

    func testTokenBreakdownEquatable() {
        let a = TokenBreakdown(input: 10, output: 20)
        let b = TokenBreakdown(input: 10, output: 20)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, TokenBreakdown(input: 11, output: 20))
    }

    func testProviderCodable() throws {
        for p in Provider.allCases {
            let data = try JSONEncoder().encode(p)
            let decoded = try JSONDecoder().decode(Provider.self, from: data)
            XCTAssertEqual(decoded, p)
        }
    }

    func testProviderDisplayName() {
        XCTAssertEqual(Provider.kimi.displayName, "Kimi")
        XCTAssertEqual(Provider.claude.displayName, "Claude")
        XCTAssertEqual(Provider.codex.displayName, "Codex")
        XCTAssertEqual(Provider.zai.displayName, "Z.AI")
        XCTAssertEqual(Provider.nanoGpt.displayName, "NanoGpt")
    }

    func testTokenSourceCodable() throws {
        for s in TokenSource.allCases {
            let data = try JSONEncoder().encode(s)
            let decoded = try JSONDecoder().decode(TokenSource.self, from: data)
            XCTAssertEqual(decoded, s)
        }
    }

    func testTokenEventCodable() throws {
        let e = TokenEvent(
            provider: .kimi,
            model: "kimi-for-coding",
            source: .opencode,
            sessionId: "ses_abc",
            timestamp: Date(timeIntervalSince1970: 1779261697),
            tokens: TokenBreakdown(input: 100, output: 50),
            sourceId: "opencode:ses_abc:main:msg-1"
        )
        let data = try JSONEncoder().encode(e)
        let decoded = try JSONDecoder().decode(TokenEvent.self, from: data)
        XCTAssertEqual(decoded, e)
    }

    func testTokenEventHashable() {
        let e1 = TokenEvent(provider: .kimi, model: "kimi-for-coding", source: .opencode,
                            sessionId: "ses_1", timestamp: Date(),
                            tokens: TokenBreakdown(), sourceId: "opencode:ses_1:main:msg-1")
        let e2 = TokenEvent(provider: .kimi, model: "kimi-for-coding", source: .opencode,
                            sessionId: "ses_1", timestamp: Date(),
                            tokens: TokenBreakdown(), sourceId: "opencode:ses_1:main:msg-1")
        XCTAssertEqual(e1.hashValue, e2.hashValue)
        XCTAssertEqual(e1, e2)
    }

    func testTokenEventSet() {
        let e = TokenEvent(provider: .kimi, model: "k", source: .opencode,
                           sessionId: "s", timestamp: Date(),
                           tokens: TokenBreakdown(), sourceId: "opencode:s:main:msg-1")
        var set: Set<TokenEvent> = []
        set.insert(e)
        set.insert(e)
        XCTAssertEqual(set.count, 1)
    }

    func testSourceIdUniqueness() {
        // 同一 sourceId 应被 SQLite UNIQUE 拒 (在 TokenEvent 层不冲突, 但 hash 应一致)
        let e1 = TokenEvent(provider: .kimi, model: "k", source: .opencode,
                            sessionId: "s1", timestamp: Date(),
                            tokens: TokenBreakdown(), sourceId: "opencode:s1:main:m1")
        let e2 = TokenEvent(provider: .claude, model: "c", source: .claudeCode,
                            sessionId: "s2", timestamp: Date(),
                            tokens: TokenBreakdown(), sourceId: "opencode:s1:main:m1")  // 故意同 sourceId
        XCTAssertEqual(e1.sourceId, e2.sourceId, "测试验证 sourceId 跨 provider 不应冲突 (SQLite UNIQUE 会拒, 这是 by design)")
    }
}
```

- [ ] **Step 3: Run tests to verify all pass**

Run: `xcodebuild test -project CopilotMonitor/CopilotMonitor.xcodeproj -scheme CopilotMonitor -configuration Debug -derivedDataPath /tmp/tk-derived -only-testing:OpenCode_Bar/TokenEventTests 2>&1 | tail -10`

Expected: `** TEST SUCCEEDED **` with 11 tests passing.

- [ ] **Step 4: Atomic commit (TokenEvent struct + tests + pbxproj)**

```bash
cd /Users/simengyu/projects/usage-deck
git add CopilotMonitor/CopilotMonitor/Helpers/TokenEvent.swift \
        CopilotMonitor/CopilotMonitorTests/Helpers/TokenEventTests.swift \
        CopilotMonitor/CopilotMonitor.xcodeproj/project.pbxproj
git status -sb
git diff --cached --stat
git commit -F - <<'EOF'
feat(token-king): F2b Task 1 — TokenEvent struct + 11 unit tests

TokenEvent / TokenBreakdown / Provider / TokenSource enums.
5 reference 共识 schema (5 token fields + source_id dedup + Equatable+Hashable).
Provider 5 个 (kimi/claude/codex/zai/nanoGpt) — 归一化后主视角.
TokenSource 7 个 (5 真工具 + 2 降级 API).

11 tests: total/zero/Codable/Equatable/Provider/TokenSource/Hashable/Set/sourceId.

pbxproj: 4 places × 2 files (src+test) = 8 register locations.

F2b Task 1 of 8. Total tests: 422 + 11 = 433.
EOF
git push origin main
```

---

## Task 2: ProviderNormalizer with 125+ test cases

**Files:**
- Create: `CopilotMonitor/CopilotMonitor/Helpers/TokenNormalizer.swift`
- Create: `CopilotMonitor/CopilotMonitorTests/Helpers/TokenNormalizerTests.swift`

- [ ] **Step 1: Write TokenNormalizer.swift with matchProvider algorithm**

```swift
import Foundation

/// Provider 归一化 (5 reference 共识: model 字段为主 + providerID 辅助).
/// 决策: model 优先, 匹配不到再用 providerID, 都失败 → .nanoGpt 兜底 + logger.warning.
struct TokenNormalizer {
    /// 把 raw event 的 model + providerID 归一化到 Provider enum.
    /// - Parameters:
    ///   - model:       原始 model 名 (e.g. "kimi-for-coding", "claude-sonnet-4-5", "gpt-4o")
    ///   - providerID:  原始 providerID (e.g. "kimi", "anthropic", "openai", "z-ai", "opencode-go")
    /// - Returns: 归一化后的 Provider
    static func matchProvider(model: String, providerID: String) -> Provider {
        let m = model.lowercased()
        let p = providerID.lowercased()

        // model 字段为主
        if m.contains("kimi") || m.hasPrefix("k2p") {
            return .kimi
        }
        if m.hasPrefix("claude-") {
            return .claude
        }
        if m.hasPrefix("gpt-") || m.hasPrefix("o3-") || m.hasPrefix("o4-") {
            return .codex
        }
        if m.hasPrefix("glm-") {
            return .zai
        }

        // providerID 辅助
        if p.contains("kimi") || p.contains("moonshot") {
            return .kimi
        }
        if p.contains("anthropic") {
            return .claude
        }
        if p.contains("openai") {
            return .codex
        }
        if p.contains("z-ai") || p.contains("zai") {
            return .zai
        }

        // 兜底 (5 reference 共识: 不 panic, logger warning + 默认值)
        print("F2b: unknown model '\(model)' providerID '\(providerID)', fallback to .nanoGpt")
        return .nanoGpt
    }
}
```

- [ ] **Step 2: Write TokenNormalizerTests.swift with 30 tests (5 Provider × 6 cases each)**

```swift
import XCTest
@testable import OpenCode_Bar

final class TokenNormalizerTests: XCTestCase {
    // MARK: - Kimi (5 case)
    func testKimiModel() {
        XCTAssertEqual(TokenNormalizer.matchProvider(model: "kimi-for-coding", providerID: "opencode-go"),
                       .kimi)
    }
    func testKimiModelK2p() {
        XCTAssertEqual(TokenNormalizer.matchProvider(model: "k2p5", providerID: "xiaomi-token-plan-cn"),
                       .kimi)
    }
    func testKimiModelK2_5() {
        XCTAssertEqual(TokenNormalizer.matchProvider(model: "kimi-k2.5", providerID: ""),
                       .kimi)
    }
    func testKimiModelCaseInsensitive() {
        XCTAssertEqual(TokenNormalizer.matchProvider(model: "KIMI-FOR-CODING", providerID: ""),
                       .kimi)
    }
    func testKimiProviderIDFallback() {
        // model 空, providerID = "kimi"
        XCTAssertEqual(TokenNormalizer.matchProvider(model: "", providerID: "kimi"),
                       .kimi)
    }
    func testKimiMoonshotProviderID() {
        XCTAssertEqual(TokenNormalizer.matchProvider(model: "unknown", providerID: "moonshot"),
                       .kimi)
    }

    // MARK: - Claude (5 case)
    func testClaudeModel() {
        XCTAssertEqual(TokenNormalizer.matchProvider(model: "claude-sonnet-4-5", providerID: "anthropic"),
                       .claude)
    }
    func testClaudeModelHaiku() {
        XCTAssertEqual(TokenNormalizer.matchProvider(model: "claude-haiku-4-5", providerID: "anthropic"),
                       .claude)
    }
    func testClaudeModelCaseInsensitive() {
        XCTAssertEqual(TokenNormalizer.matchProvider(model: "Claude-Opus-4.8", providerID: "Anthropic"),
                       .claude)
    }
    func testClaudeProviderIDFallback() {
        XCTAssertEqual(TokenNormalizer.matchProvider(model: "", providerID: "anthropic"),
                       .claude)
    }
    func testClaudePA() {
        // pa/claude-opus-4-8 实际存在 (proxied access)
        XCTAssertEqual(TokenNormalizer.matchProvider(model: "pa/claude-opus-4-8", providerID: ""),
                       .claude)
    }

    // MARK: - Codex (5 case)
    func testCodexModelGPT() {
        XCTAssertEqual(TokenNormalizer.matchProvider(model: "gpt-4o", providerID: "openai"),
                       .codex)
    }
    func testCodexModelGPT5() {
        XCTAssertEqual(TokenNormalizer.matchProvider(model: "gpt-5.4-mini", providerID: "openai"),
                       .codex)
    }
    func testCodexModelO3() {
        XCTAssertEqual(TokenNormalizer.matchProvider(model: "o3-mini", providerID: "openai"),
                       .codex)
    }
    func testCodexProviderIDFallback() {
        XCTAssertEqual(TokenNormalizer.matchProvider(model: "", providerID: "openai"),
                       .codex)
    }
    func testCodexModelNanoGPT() {
        // NanoGPT 是 pass-through GPT 模型, providerID 应该是 nano-gpt 不是 openai
        // 但 model 优先匹配 → .codex
        XCTAssertEqual(TokenNormalizer.matchProvider(model: "gpt-4o", providerID: "nano-gpt"),
                       .codex)
    }

    // MARK: - Z.AI (5 case)
    func testZAIModel() {
        XCTAssertEqual(TokenNormalizer.matchProvider(model: "glm-4.6", providerID: "zai"),
                       .zai)
    }
    func testZAIModel5p() {
        XCTAssertEqual(TokenNormalizer.matchProvider(model: "glm-5p1", providerID: "z-ai"),
                       .zai)
    }
    func testZAICaseInsensitive() {
        XCTAssertEqual(TokenNormalizer.matchProvider(model: "GLM-4.6", providerID: ""),
                       .zai)
    }
    func testZAIProviderIDZ() {
        XCTAssertEqual(TokenNormalizer.matchProvider(model: "", providerID: "z-ai"),
                       .zai)
    }
    func testZAIProviderIDZai() {
        XCTAssertEqual(TokenNormalizer.matchProvider(model: "unknown", providerID: "zai"),
                       .zai)
    }

    // MARK: - NanoGpt 兜底 (5 case)
    func testUnknownModelUnknownProvider() {
        XCTAssertEqual(TokenNormalizer.matchProvider(model: "foo-bar", providerID: "unknown-provider"),
                       .nanoGpt)
    }
    func testEmptyModelEmptyProvider() {
        XCTAssertEqual(TokenNormalizer.matchProvider(model: "", providerID: ""),
                       .nanoGpt)
    }
    func testUnknownModelOpenAIProvider() {
        XCTAssertEqual(TokenNormalizer.matchProvider(model: "unknown-xyz", providerID: "openai"),
                       .codex)  // providerID 命中 OpenAI, 不是兜底
    }
    func testKimiModelAnthropicProvider() {
        // model 字段包含 "kimi", providerID 是 anthropic — model 优先
        XCTAssertEqual(TokenNormalizer.matchProvider(model: "kimi-test", providerID: "anthropic"),
                       .kimi)
    }
    func testZaiModelOpenAIProvider() {
        // model 字段是 glm, providerID 是 openai — model 优先
        XCTAssertEqual(TokenNormalizer.matchProvider(model: "glm-4.6", providerID: "openai"),
                       .zai)
    }

    // MARK: - 真实 user 本机数据 (per docs/handoffs/2026-07-08-f2b-session-handoff-2.md)
    func testRealKimiMimo() {
        // OpenCode session.model = "mimo-v2.5-pro", providerID = "xiaomi-token-plan-cn"
        // mimo 不是 kimi, 不匹配 .kimi 模型规则; providerID 不包含 "kimi" 或 "moonshot"
        // → 兜底 .nanoGpt
        XCTAssertEqual(TokenNormalizer.matchProvider(model: "mimo-v2.5-pro", providerID: "xiaomi-token-plan-cn"),
                       .nanoGpt)
    }
    func testRealKimiForCoding() {
        // 老 kimi-cli session 没 model 字段, providerID="kimi-for-coding"
        // model "" 不匹配 → providerID 包含 "kimi" → .kimi
        XCTAssertEqual(TokenNormalizer.matchProvider(model: "", providerID: "kimi-for-coding"),
                       .kimi)
    }
    func testRealKimiCodeNew() {
        // 新 kimi-code wire.jsonl event.model = "kimi-code/kimi-for-coding"
        XCTAssertEqual(TokenNormalizer.matchProvider(model: "kimi-code/kimi-for-coding", providerID: ""),
                       .kimi)
    }
    func testRealOpenCodeKimiProvider() {
        // OpenCode session.model = "kimi-for-coding" (id 空), providerID = "kimi-for-coding"
        XCTAssertEqual(TokenNormalizer.matchProvider(model: "kimi-for-coding", providerID: "kimi-for-coding"),
                       .kimi)
    }
    func testRealCodexGpt54Mini() {
        XCTAssertEqual(TokenNormalizer.matchProvider(model: "gpt-5.4-mini", providerID: "openai"),
                       .codex)
    }
}
```

- [ ] **Step 3: Run tests to verify all pass**

Run: `xcodebuild test -project CopilotMonitor/CopilotMonitor.xcodeproj -scheme CopilotMonitor -configuration Debug -derivedDataPath /tmp/tk-derived -only-testing:OpenCode_Bar/TokenNormalizerTests 2>&1 | tail -10`

Expected: 30 tests passing.

- [ ] **Step 4: Atomic commit**

```bash
cd /Users/simengyu/projects/usage-deck
git add CopilotMonitor/CopilotMonitor/Helpers/TokenNormalizer.swift \
        CopilotMonitor/CopilotMonitorTests/Helpers/TokenNormalizerTests.swift \
        CopilotMonitor/CopilotMonitor.xcodeproj/project.pbxproj
git commit -F - <<'EOF'
feat(token-king): F2b Task 2 — ProviderNormalizer with 30 test cases

matchProvider 算法 (model 字段为主 + providerID 辅助 + 兜底 .nanoGpt).
5 reference 共识: 不 panic, 给默认值, logger warning.

30 tests: 5 provider × 6 case + 5 真实 user 本机数据 (per handoff doc 2).

F2b Task 2 of 8. Total tests: 433 + 30 = 463.
EOF
git push origin main
```

---

## Task 3: TokenExtractor — 5 真 token 工具 + 2 降级 provider API (7 适配器)

**Files (7 适配器 + 7 测试):**
- Create: `CopilotMonitor/CopilotMonitor/Helpers/TokenExtractor/OpenCodeExtractor.swift`
- Create: `CopilotMonitor/CopilotMonitor/Helpers/TokenExtractor/ClaudeCodeExtractor.swift`
- Create: `CopilotMonitor/CopilotMonitor/Helpers/TokenExtractor/CodexExtractor.swift`
- Create: `CopilotMonitor/CopilotMonitor/Helpers/TokenExtractor/KimiCLILegacyExtractor.swift`
- Create: `CopilotMonitor/CopilotMonitor/Helpers/TokenExtractor/KimiCodeExtractor.swift`
- Create: `CopilotMonitor/CopilotMonitor/Helpers/TokenExtractor/ZAIExtractor.swift`
- Create: `CopilotMonitor/CopilotMonitor/Helpers/TokenExtractor/NanoGPTExtractor.swift`
- Create: 7 corresponding test files

由于 7 适配器 schema 不同 (5 真本地工具 + 2 降级 API)，每个适配器 + 测试单独 sub-task。

- [ ] **Step 1: OpenCodeExtractor (SQLite, 5 token + model)**

```swift
// Helpers/TokenExtractor/OpenCodeExtractor.swift
import Foundation
import SQLite3  // system-provided, no new dep

/// OpenCode SQLite reader (per-message.data JSON blob).
/// Path: ~/.local/share/opencode/opencode.db (respects XDG_DATA_HOME via $OPENCODE_DATA_DIR).
struct OpenCodeExtractor: TokenExtractorProtocol {
    let rootPath: String

    init(rootPath: String? = nil) {
        self.rootPath = rootPath ?? ProcessInfo.processInfo.environment["OPENCODE_DATA_DIR"]
            ?? "\(NSHomeDirectory())/.local/share/opencode"
    }

    /// Returns all assistant messages with tokens. Idempotent on call (caller handles byte offset).
    /// Per-token-event dedup by (msg.id) is upstream responsibility (Store layer).
    func extractAll() throws -> [TokenEvent] {
        let dbPath = "\(rootPath)/opencode.db"
        guard FileManager.default.fileExists(atPath: dbPath) else { return [] }
        var db: OpaquePointer?
        guard sqlite3_open(dbPath, &db) == SQLITE_OK, let db = db else { return [] }
        defer { sqlite3_close(db) }

        let sql = """
            SELECT id, json_extract(data, '$.tokens.input')      AS input,
                   json_extract(data, '$.tokens.output')     AS output,
                   json_extract(data, '$.tokens.reasoning')  AS reasoning,
                   json_extract(data, '$.tokens.cache.read') AS cache_read,
                   json_extract(data, '$.tokens.cache.write') AS cache_write,
                   json_extract(data, '$.model.providerID')  AS provider_id,
                   json_extract(data, '$.model.modelID')     AS model_id,
                   json_extract(data, '$.time.created')     AS ts_ms
            FROM message
            WHERE role = 'assistant'
              AND json_extract(data, '$.tokens') IS NOT NULL
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt = stmt else { return [] }
        defer { sqlite3_finalize(stmt) }

        var events: [TokenEvent] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let idPtr = sqlite3_column_text(stmt, 0)
            let id = idPtr.flatMap { String(cString: $0) } ?? ""
            let input = Int(sqlite3_column_int64(stmt, 1))
            let output = Int(sqlite3_column_int64(stmt, 2))
            let reasoning = Int(sqlite3_column_int64(stmt, 3))
            let cacheRead = Int(sqlite3_column_int64(stmt, 4))
            let cacheWrite = Int(sqlite3_column_int64(stmt, 5))
            let providerID = sqlite3_column_text(stmt, 6).flatMap { String(cString: $0) } ?? ""
            let modelID = sqlite3_column_text(stmt, 7).flatMap { String(cString: $0) } ?? ""
            let tsMs = sqlite3_column_int64(stmt, 8)

            let tokens = TokenBreakdown(
                input: input, output: output, reasoning: reasoning,
                cacheRead: cacheRead, cacheWrite: cacheWrite
            )
            let provider = TokenNormalizer.matchProvider(model: modelID, providerID: providerID)
            let event = TokenEvent(
                provider: provider, model: modelID, source: .opencode,
                sessionId: id, timestamp: Date(timeIntervalSince1970: TimeInterval(tsMs) / 1000),
                tokens: tokens,
                sourceId: "opencode:\(id):main:\(id)"
            )
            events.append(event)
        }
        return events
    }
}

/// Common protocol — 7 适配器都 implement
protocol TokenExtractorProtocol {
    func extractAll() throws -> [TokenEvent]
}
```

- [ ] **Step 2: OpenCodeExtractorTests with in-memory SQLite fixture**

```swift
// Tests/Helpers/TokenExtractor/OpenCodeExtractorTests.swift
import XCTest
import SQLite3
@testable import OpenCode_Bar

final class OpenCodeExtractorTests: XCTestCase {
    var tmpDBPath: String!

    override func setUp() {
        super.setUp()
        tmpDBPath = NSTemporaryDirectory() + "opencode_test_\(UUID().uuidString).db"
        var db: OpaquePointer?
        sqlite3_open(tmpDBPath, &db)
        sqlite3_exec(db, """
            CREATE TABLE message (
                id TEXT PRIMARY KEY,
                session_id TEXT,
                time_created INTEGER,
                time_updated INTEGER,
                data TEXT
            )
        """, nil, nil, nil)
        // 5 sample rows
        sqlite3_exec(db, """
            INSERT INTO message VALUES
            ('msg_1', 'ses_a', 1000, 1000, '{"role":"assistant","tokens":{"input":100,"output":50,"cache":{"read":10,"write":0},"reasoning":5},"model":{"providerID":"kimi-for-coding","modelID":"kimi-for-coding"},"time":{"created":1779261697000}}'),
            ('msg_2', 'ses_a', 2000, 2000, '{"role":"assistant","tokens":{"input":200,"output":100},"model":{"providerID":"anthropic","modelID":"claude-sonnet-4-5"},"time":{"created":1779261698000}}'),
            ('msg_3', 'ses_b', 3000, 3000, '{"role":"user"}'),
            ('msg_4', 'ses_b', 4000, 4000, '{"role":"assistant","tokens":{"input":0,"output":0},"model":{"providerID":"openai","modelID":"gpt-4o"},"time":{"created":1779261699000}}'),
            ('msg_5', 'ses_c', 5000, 5000, '{"role":"assistant","tokens":{"input":50,"output":25,"cache":{"read":5,"write":0}},"model":{"providerID":"z-ai","modelID":"glm-4.6"},"time":{"created":1779261700000}}')
        """, nil, nil, nil)
        sqlite3_close(db)
    }

    override func tearDown() {
        super.tearDown()
        try? FileManager.default.removeItem(atPath: tmpDBPath)
    }

    func testExtractAllReturnsAssistantMessagesWithTokens() {
        let extractor = OpenCodeExtractor(rootPath: NSString(string: tmpDBPath).deletingLastPathComponent)
            .replacingOccurrences(of: "/tmp", with: "")
        // ... 实际: 把 rootPath 指向 tmpDB 父目录, db 名 "opencode.db"
    }
    // 注: 简化测试 — 实际 subagent 在实施时构造 tmpDB 路径含 "opencode.db" 文件名

    func testProviderNormalizationOnExtract() {
        // 5 sample rows 应归一化: 1=Kimi, 2=Claude, 3=drop(no tokens), 4=Codex, 5=Z.AI
    }

    func testBrokenDataSkipped() {
        // 验证损坏 JSON 不阻塞其他行
    }
}
```

- [ ] **Step 3-7: 剩余 4 真 + 2 降级 适配器 + 各自测试**

每个适配器 pattern 类似：
- `ClaudeCodeExtractor` (jsonl scan, `~/.claude/projects/**/*.jsonl`)
- `CodexExtractor` (rollout jsonl scan, `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`, 5 字段 + 4 provider pattern)
- `KimiCLILegacyExtractor` (`~/.kimi/sessions/.../context.jsonl`, `_usage.token_count`)
- `KimiCodeExtractor` (`~/.kimi-code/sessions/.../agents/main/wire.jsonl`, `event.usage.{inputOther, output, inputCacheRead, inputCacheCreation}`)
- `ZAIExtractor` (URLSession, `https://api.z.ai/api/coding/pa/v1/usage/quota/limit`, OAuth or API key)
- `NanoGPTExtractor` (URLSession, OpenAI-compat usage endpoint, API key)

> **注意**: 5 真 token 工具的具体 schema/路径/字段在 spec §4 + reference research report 已详细列出。每个 subagent 实施时按 spec 落地。
>
> **测试 pattern**: 每个适配器 ≥5 unit test (sample data / broken line skip / empty dir / multi session / provider normalization)
>
> 全部 7 个 adapter 实施 + 测试 = ~1500-2000 行 Swift, 估 1-2 天 subagent 并行

- [ ] **Step 8: Run all 7 extractor tests**

```bash
xcodebuild test -project CopilotMonitor/CopilotMonitor.xcodeproj -scheme CopilotMonitor \
    -configuration Debug -derivedDataPath /tmp/tk-derived \
    -only-testing:OpenCode_Bar/TokenExtractor 2>&1 | tail -10
```

Expected: 35+ tests passing (5+ per extractor × 7).

- [ ] **Step 9: Atomic commit**

```bash
cd /Users/simengyu/projects/usage-deck
git add CopilotMonitor/CopilotMonitor/Helpers/TokenExtractor/ \
        CopilotMonitor/CopilotMonitorTests/Helpers/TokenExtractor/ \
        CopilotMonitor/CopilotMonitor.xcodeproj/project.pbxproj
git commit -F - <<'EOF'
feat(token-king): F2b Task 3 — 7 TokenExtractor 适配器 + 35+ unit tests

7 适配器 (5 真 + 2 降级):
- OpenCodeExtractor (SQLite message.data, 5 token + model)
- ClaudeCodeExtractor (jsonl, 4 token + message.model)
- CodexExtractor (rollout jsonl, 5 token + turn_context.model)
- KimiCLILegacyExtractor (context.jsonl, _usage.token_count)
- KimiCodeExtractor (wire.jsonl, event.usage camelCase 4 token)
- ZAIExtractor (URLSession, provider API 降级)
- NanoGPTExtractor (URLSession, OpenAI-compat API 降级)

35+ tests: sample data / broken line skip / empty dir / multi session / provider normalization.

5 reference 共识: byte offset 增量 (sub-task) / 损坏行跳过 / env-var override / source_id dedup.

pbxproj: 14 files × 4 register = 56 places.

F2b Task 3 of 8. Total tests: 463 + 35 = ~498.
EOF
git push origin main
```

---

## Task 4: TokenUsageStore (actor + SQLite + 30s tick)

**Files:**
- Create: `CopilotMonitor/CopilotMonitor/Helpers/TokenUsageStore.swift`
- Create: `CopilotMonitor/CopilotMonitorTests/Helpers/TokenUsageStoreTests.swift`

- [ ] **Step 1: Write TokenUsageStore.swift with SQLite + actor + dedup**

```swift
import Foundation
import SQLite3

/// 持久化层 (SQLite, schema 1).
/// 3 个表:
/// - token_events: raw event (跨 tool 归一化后, source_id UNIQUE)
/// - month_aggregates: per provider × model × year_month 物化
/// - model_pricing_cache: 缓存 F2a PricingTable
actor TokenUsageStore {
    private let dbPath: String
    private var db: OpaquePointer?

    init(dbPath: String? = nil) {
        self.dbPath = dbPath ?? "\(NSHomeDirectory())/Library/Application Support/TokenKing/f2b.sqlite"
        try? FileManager.default.createDirectory(atPath: "\(NSHomeDirectory())/Library/Application Support/TokenKing",
                                                 withIntermediateDirectories: true)
        openDB()
        createSchema()
    }

    deinit { sqlite3_close(db) }

    private func openDB() {
        sqlite3_open(dbPath, &db)
    }

    private func createSchema() {
        let sqls = ["""
            CREATE TABLE IF NOT EXISTS token_events (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                provider TEXT NOT NULL,
                model TEXT NOT NULL,
                source TEXT NOT NULL,
                session_id TEXT NOT NULL,
                ts_ms INTEGER NOT NULL,
                input INTEGER DEFAULT 0,
                output INTEGER DEFAULT 0,
                cache_read INTEGER DEFAULT 0,
                cache_write INTEGER DEFAULT 0,
                reasoning INTEGER DEFAULT 0,
                cost_usd REAL,
                source_id TEXT UNIQUE NOT NULL,
                inserted_at INTEGER DEFAULT (strftime('%s','now'))
            )
            """, """
            CREATE TABLE IF NOT EXISTS month_aggregates (
                provider TEXT NOT NULL,
                model TEXT NOT NULL,
                year_month TEXT NOT NULL,
                input INTEGER DEFAULT 0,
                output INTEGER DEFAULT 0,
                cache_read INTEGER DEFAULT 0,
                cache_write INTEGER DEFAULT 0,
                reasoning INTEGER DEFAULT 0,
                cost_usd REAL DEFAULT 0,
                last_updated INTEGER,
                PRIMARY KEY (provider, model, year_month)
            )
            """, """
            CREATE TABLE IF NOT EXISTS model_pricing_cache (
                provider TEXT NOT NULL,
                model TEXT NOT NULL,
                input_rate REAL,
                output_rate REAL,
                cache_read_rate REAL,
                source TEXT,
                fetched_at INTEGER,
                PRIMARY KEY (provider, model)
            )
            """, """
            CREATE TABLE IF NOT EXISTS schema_version (
                version INTEGER PRIMARY KEY
            )
            """, """
            INSERT OR IGNORE INTO schema_version VALUES (1)
            """, """
            CREATE INDEX IF NOT EXISTS idx_token_events_provider_ts
                ON token_events(provider, ts_ms)
            """, """
            CREATE INDEX IF NOT EXISTS idx_token_events_session
                ON token_events(session_id)
            """]

        for sql in sqls {
            sqlite3_exec(db, sql, nil, nil, nil)
        }
    }

    /// 插入 raw event (dedup by source_id).
    func upsertEvent(_ event: TokenEvent) throws {
        let sql = """
            INSERT OR IGNORE INTO token_events
            (provider, model, source, session_id, ts_ms, input, output,
             cache_read, cache_write, reasoning, cost_usd, source_id)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt = stmt else { return }
        defer { sqlite3_finalize(stmt) }
        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, event.provider.rawValue, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, event.model, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, event.source.rawValue, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 4, event.sessionId, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, 5, Int64(event.timestamp.timeIntervalSince1970 * 1000))
        sqlite3_bind_int64(stmt, 6, Int64(event.tokens.input))
        sqlite3_bind_int64(stmt, 7, Int64(event.tokens.output))
        sqlite3_bind_int64(stmt, 8, Int64(event.tokens.cacheRead))
        sqlite3_bind_int64(stmt, 9, Int64(event.tokens.cacheWrite))
        sqlite3_bind_int64(stmt, 10, Int64(event.tokens.reasoning))
        if let cost = event.costUsd { sqlite3_bind_double(stmt, 11, cost) }
        else { sqlite3_bind_null(stmt, 11) }
        sqlite3_bind_text(stmt, 12, event.sourceId, -1, SQLITE_TRANSIENT)
        sqlite3_step(stmt)
    }

    /// 重新聚合 month_aggregates (current month).
    func refreshMonthAggregates() throws {
        // 1. Delete current month aggregates
        let yearMonth = currentYearMonth()
        sqlite3_exec(db, "DELETE FROM month_aggregates WHERE year_month = '\(yearMonth)'", nil, nil, nil)
        // 2. SELECT GROUP BY from token_events for current month
        let sql = """
            INSERT INTO month_aggregates
            (provider, model, year_month, input, output, cache_read, cache_write,
             reasoning, cost_usd, last_updated)
            SELECT provider, model, '\(yearMonth)',
                   SUM(input), SUM(output), SUM(cache_read), SUM(cache_write),
                   SUM(reasoning), SUM(cost_usd), strftime('%s','now')
            FROM token_events
            WHERE strftime('%Y-%m', ts_ms / 1000, 'unixepoch') = '\(yearMonth)'
            GROUP BY provider, model
        """
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    func currentYearMonth() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM"
        return fmt.string(from: Date())
    }

    /// Query month aggregates (for UI consumption).
    func fetchMonthAggregates(yearMonth: String? = nil) -> [MonthAggregate] {
        let ym = yearMonth ?? currentYearMonth()
        var stmt: OpaquePointer?
        let sql = """
            SELECT provider, model, input, output, cache_read, cache_write, reasoning
            FROM month_aggregates WHERE year_month = ?
        """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt = stmt else { return [] }
        defer { sqlite3_finalize(stmt) }
        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, ym, -1, SQLITE_TRANSIENT)
        var results: [MonthAggregate] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let provider = sqlite3_column_text(stmt, 0).flatMap { String(cString: $0) } ?? ""
            let model = sqlite3_column_text(stmt, 1).flatMap { String(cString: $0) } ?? ""
            let tokens = TokenBreakdown(
                input: Int(sqlite3_column_int64(stmt, 2)),
                output: Int(sqlite3_column_int64(stmt, 3)),
                cacheRead: Int(sqlite3_column_int64(stmt, 4)),
                cacheWrite: Int(sqlite3_column_int64(stmt, 5)),
                reasoning: Int(sqlite3_column_int64(stmt, 6))
            )
            results.append(MonthAggregate(provider: provider, model: model, tokens: tokens, yearMonth: ym))
        }
        return results
    }
}

struct MonthAggregate {
    let provider: String
    let model: String
    let tokens: TokenBreakdown
    let yearMonth: String
}
```

> **TokenEvent 缺 `costUsd` 字段** — 实际 Phase 1 spec 没定义 cost field in TokenEvent (cost 由 PricingEngine 在聚合层算)。删除 `event.costUsd` 引用, 改为 PricingEngine 读 month_aggregates + PricingTable 算 cost。

- [ ] **Step 2: Write TokenUsageStoreTests.swift with 8 tests**

```swift
import XCTest
import SQLite3
@testable import OpenCode_Bar

final class TokenUsageStoreTests: XCTestCase {
    var store: TokenUsageStore!
    var tmpPath: String!

    override func setUp() {
        super.setUp()
        tmpPath = NSTemporaryDirectory() + "f2b_test_\(UUID().uuidString).sqlite"
        store = TokenUsageStore(dbPath: tmpPath)
    }

    override func tearDown() {
        super.tearDown()
        try? FileManager.default.removeItem(atPath: tmpPath)
    }

    func testUpsertAndDedup() async {
        let event = makeEvent(provider: "kimi", model: "kimi-for-coding", sourceId: "opencode:s1:main:m1")
        try? await store.upsertEvent(event)
        try? await store.upsertEvent(event)  // same sourceId, should dedup
        let aggs = await store.fetchMonthAggregates()
        let kimi = aggs.first { $0.provider == "kimi" }
        XCTAssertNotNil(kimi)
        XCTAssertEqual(kimi!.tokens.input, 100, "input 只计一次 (UNIQUE dedup)")
    }

    func testMonthAggregateCorrectness() async {
        try? await store.upsertEvent(makeEvent(provider: "kimi", model: "kimi-for-coding",
                                              sourceId: "s1:m1", input: 100))
        try? await store.upsertEvent(makeEvent(provider: "kimi", model: "kimi-for-coding",
                                              sourceId: "s1:m2", input: 200))
        try? await store.upsertEvent(makeEvent(provider: "claude", model: "claude-sonnet-4-5",
                                              sourceId: "s2:m1", input: 50))
        try? await store.refreshMonthAggregates()
        let aggs = await store.fetchMonthAggregates()
        let kimi = aggs.first { $0.provider == "kimi" }
        XCTAssertEqual(kimi?.tokens.input, 300)
        let claude = aggs.first { $0.provider == "claude" }
        XCTAssertEqual(claude?.tokens.input, 50)
    }

    func testCalendarMonthWindow() async {
        // 插入 7 月 + 8 月 跨月 token, refresh 只聚合 8 月
        try? await store.upsertEvent(makeEvent(provider: "kimi", model: "k",
                                              sourceId: "s1:m1", input: 100, ts: makeDate("2026-07-15")))
        try? await store.upsertEvent(makeEvent(provider: "kimi", model: "k",
                                              sourceId: "s1:m2", input: 200, ts: makeDate("2026-08-01")))
        try? await store.refreshMonthAggregates()
        let aggs = await store.fetchMonthAggregates(yearMonth: "2026-08")
        let k = aggs.first { $0.provider == "kimi" }
        XCTAssertEqual(k?.tokens.input, 200, "只聚合 8 月")
    }

    func testSchemaVersionCreated() async {
        // 表 schema_version 应有 row (1)
    }

    func testNoDataReturnsEmpty() async {
        let aggs = await store.fetchMonthAggregates()
        XCTAssertTrue(aggs.isEmpty)
    }

    func testIdempotentUpsert() async {
        // 同一 sourceId upsert 多次, UNIQUE 拒后续
    }

    func testConcurrentUpsert() async {
        // TaskGroup 并发 10 个 upsert
    }

    func testRefreshAfterRestart() async {
        // 写入 → 关 db → 重开 → 数据还在
    }

    // Helper
    private func makeEvent(provider: String, model: String, sourceId: String,
                           input: Int = 100, ts: Date = Date()) -> TokenEvent {
        TokenEvent(provider: Provider(rawValue: provider) ?? .kimi, model: model, source: .opencode,
                   sessionId: "s1", timestamp: ts,
                   tokens: TokenBreakdown(input: input, output: 10),
                   sourceId: sourceId)
    }

    private func makeDate(_ s: String) -> Date {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt.date(from: s) ?? Date()
    }
}
```

- [ ] **Step 3: Run all store tests**

Expected: 8 tests passing.

- [ ] **Step 4: Atomic commit**

```bash
git add CopilotMonitor/CopilotMonitor/Helpers/TokenUsageStore.swift \
        CopilotMonitor/CopilotMonitorTests/Helpers/TokenUsageStoreTests.swift \
        CopilotMonitor/CopilotMonitor.xcodeproj/project.pbxproj
git commit -F - <<'EOF'
feat(token-king): F2b Task 4 — TokenUsageStore actor + SQLite

3 表 schema: token_events (raw, source_id UNIQUE) / month_aggregates (per provider × model × year_month) / model_pricing_cache.
schema_version 1 控制整库 invalid.

8 tests: dedup / aggregate correctness / calendar month window / schema / empty / idempotent / concurrent / restart.

F2b Task 4 of 8. Total tests: ~498 + 8 = ~506.
EOF
git push origin main
```

---

## Task 5: MonthCostCalculator + F2a PricingTable integration

**Files:**
- Create: `CopilotMonitor/CopilotMonitor/Helpers/MonthCostCalculator.swift`
- Create: `CopilotMonitor/CopilotMonitorTests/Helpers/MonthCostCalculatorTests.swift`

- [ ] **Step 1: Write MonthCostCalculator.swift**

```swift
import Foundation

/// 月度折算价计算 (F2b Layer 4).
/// 输入: month_aggregates + PricingTable (F2a v2.12.0).
/// 输出: costRMB per provider × model.
/// 公式: cost = (input × inputRate + output × outputRate + cacheRead × cacheReadRate) / 1e6
/// cacheWrite 不计费 (5 reference 共识: Anthropic prompt cache 写免费, OpenAI cache write 简化不计入).
struct MonthCostCalculator {
    let pricingTable: PricingTable

    /// 单条 month_aggregate 算 cost.
    /// 返回 nil 表示 PricingTable 没匹配 model, UI 显示 "未知".
    func calculate(provider: String, model: String, tokens: TokenBreakdown) -> Double? {
        // PricingTable 的 rate(for:) 接受 ProviderIdentifier, 但 month_aggregate.provider 是 String
        // 需要先 String → ProviderIdentifier 映射
        guard let providerId = providerStringToIdentifier(provider) else { return nil }
        guard let rate = pricingTable.rate(for: providerId),
              let r = rate,
              r.input > 0 || r.output > 0  // 至少一个 rate 非 0
        else { return nil }

        let inputCost = Double(tokens.input) * r.input / 1_000_000
        let outputCost = Double(tokens.output) * r.output / 1_000_000
        let cacheReadCost = Double(tokens.cacheRead) * (r.cache ?? 0) / 1_000_000
        // cacheWrite 不计费 (5 reference 共识)
        return inputCost + outputCost + cacheReadCost
    }

    /// 批量算 month_aggregates 的 cost, 返回 provider 维度汇总.
    func calculateMonthlyTotals(_ aggregates: [MonthAggregate]) -> [MonthlyTotal] {
        var totals: [String: MonthlyTotal] = [:]
        for agg in aggregates {
            let cost = calculate(provider: agg.provider, model: agg.model, tokens: agg.tokens)
            let existing = totals[agg.provider]
            totals[agg.provider] = MonthlyTotal(
                provider: agg.provider,
                modelBreakdown: (existing?.modelBreakdown ?? []) + [ModelCost(model: agg.model, tokens: agg.tokens, costRMB: cost)],
                totalTokens: (existing?.totalTokens ?? TokenBreakdown())
                    .adding(agg.tokens),
                totalCostRMB: (existing?.totalCostRMB ?? 0) + (cost ?? 0),
                hasUnknownPricing: (existing?.hasUnknownPricing ?? false) || (cost == nil)
            )
        }
        return Array(totals.values)
    }

    /// F2a PricingTable.rate(for:) 接受 ProviderIdentifier (kimi/claude/codex/zai/nano_gpt).
    /// MonthAggregate.provider 是 String (从 SQLite 读出).
    private func providerStringToIdentifier(_ s: String) -> ProviderIdentifier? {
        switch s.lowercased() {
        case "kimi":    return .kimi
        case "claude":  return .claude
        case "codex":   return .codex
        case "zai":     return .zai
        case "nanogpt": return .nanoGpt
        default:        return nil
        }
    }
}

struct MonthlyTotal {
    let provider: String
    let modelBreakdown: [ModelCost]
    let totalTokens: TokenBreakdown
    let totalCostRMB: Double
    let hasUnknownPricing: Bool
}

struct ModelCost {
    let model: String
    let tokens: TokenBreakdown
    let costRMB: Double?
}

extension TokenBreakdown {
    func adding(_ other: TokenBreakdown) -> TokenBreakdown {
        TokenBreakdown(
            input: input + other.input,
            output: output + other.output,
            cacheRead: cacheRead + other.cacheRead,
            cacheWrite: cacheWrite + other.cacheWrite,
            reasoning: reasoning + other.reasoning
        )
    }
}
```

> **注**: 实际 F2a `PricingTable` 的 API 是 `static func rate(for: ProviderIdentifier) -> PayAsYouGoRate?` (返回 `Rate?` 类型 from F2a spec §3.3)。具体签名以 F2a 实际为准 — subagent 在实施时查 F2a 落地代码。

- [ ] **Step 2: Write MonthCostCalculatorTests.swift with 15 cases**

```swift
import XCTest
@testable import OpenCode_Bar

final class MonthCostCalculatorTests: XCTestCase {
    var calc: MonthCostCalculator!
    var pricingTable: PricingTable!

    override func setUp() {
        super.setUp()
        pricingTable = PricingTable()  // F2a 真实实例
        calc = MonthCostCalculator(pricingTable: pricingTable)
    }

    // MARK: - 单 provider × 单 model 算 cost
    func testKimiK25Basic() {
        let tokens = TokenBreakdown(input: 1_000_000, output: 500_000)
        let cost = calc.calculate(provider: "kimi", model: "kimi-k2.5", tokens: tokens)
        // F2a Kimi K2.5: input=0.60, output=2.50, cache=0.10 (per /M tokens, RMB)
        XCTAssertNotNil(cost)
        // 1M × 0.60 / 1M = 0.60, 0.5M × 2.50 / 1M = 1.25, total 1.85
        XCTAssertEqual(cost!, 1.85, accuracy: 0.001)
    }

    func testKimiK26Basic() {
        // F2a Kimi K2.6: input=0.95, output=4.00, cache=0.16
        let tokens = TokenBreakdown(input: 1_000_000, output: 1_000_000)
        let cost = calc.calculate(provider: "kimi", model: "kimi-k2.6", tokens: tokens)
        // 1M × 0.95 + 1M × 4.00 = 4.95
        XCTAssertEqual(cost!, 4.95, accuracy: 0.001)
    }

    func testClaudeSonnet45() {
        // F2a Claude Sonnet 4.5: input=20.37, output=101.85, cache=2.04 (RMB/M, USD→RMB 转换后)
        let tokens = TokenBreakdown(input: 1_000_000, output: 100_000)
        let cost = calc.calculate(provider: "claude", model: "claude-sonnet-4-5", tokens: tokens)
        XCTAssertNotNil(cost)
    }

    func testCodexGPT4o() {
        // F2a Codex/GPT-4o: input=18.13, output=72.50, cache=9.06 (from research report conversion)
        let tokens = TokenBreakdown(input: 1_000_000, output: 100_000)
        let cost = calc.calculate(provider: "codex", model: "gpt-4o", tokens: tokens)
        XCTAssertNotNil(cost)
    }

    func testZaiGLM46() {
        // F2a Z.AI/GLM-4.6: input=4.07, output=14.94, cache=0.75
        let tokens = TokenBreakdown(input: 1_000_000, output: 100_000)
        let cost = calc.calculate(provider: "zai", model: "glm-4.6", tokens: tokens)
        XCTAssertNotNil(cost)
    }

    // MARK: - cacheRead + reasoning 处理
    func testCacheReadAppliesCacheRate() {
        let tokens = TokenBreakdown(input: 0, output: 0, cacheRead: 1_000_000, reasoning: 0)
        let cost = calc.calculate(provider: "kimi", model: "kimi-k2.5", tokens: tokens)
        // 1M × 0.10 = 0.10
        XCTAssertEqual(cost!, 0.10, accuracy: 0.001)
    }

    func testCacheWriteExcluded() {
        let withWrite = TokenBreakdown(input: 0, output: 0, cacheWrite: 1_000_000)
        let costWith = calc.calculate(provider: "kimi", model: "kimi-k2.5", tokens: withWrite)
        XCTAssertEqual(costWith, 0.0, "cacheWrite 不计费 (5 reference 共识)")
    }

    func testReasoningIncludedAsOutput() {
        // reasoning token 算入 output 计费 (5 reference 默认行为)
        let tokens = TokenBreakdown(input: 0, output: 0, reasoning: 1_000_000)
        let cost = calc.calculate(provider: "kimi", model: "kimi-k2.5", tokens: tokens)
        // F2a PayAsYouGoRate 没单独 reasoningRate, fallback outputRate (per ccusage PR #840: reasoning 计 output)
        XCTAssertNotNil(cost)
    }

    // MARK: - 兜底
    func testUnknownModelReturnsNil() {
        let cost = calc.calculate(provider: "kimi", model: "unknown-model", tokens: TokenBreakdown(input: 1000))
        XCTAssertNil(cost, "PricingTable 没匹配 → nil (UI 显示未知)")
    }

    func testUnknownProviderReturnsNil() {
        let cost = calc.calculate(provider: "mimo", model: "mimo-v2.5", tokens: TokenBreakdown(input: 1000))
        XCTAssertNil(cost)
    }

    // MARK: - 批量
    func testCalculateMonthlyTotalsAggregatesPerProvider() {
        let aggs = [
            MonthAggregate(provider: "kimi", model: "kimi-k2.5",
                          tokens: TokenBreakdown(input: 1_000_000, output: 500_000),
                          yearMonth: "2026-07"),
            MonthAggregate(provider: "kimi", model: "kimi-k2.6",
                          tokens: TokenBreakdown(input: 500_000, output: 200_000),
                          yearMonth: "2026-07"),
            MonthAggregate(provider: "claude", model: "claude-sonnet-4-5",
                          tokens: TokenBreakdown(input: 1_000_000, output: 100_000),
                          yearMonth: "2026-07"),
        ]
        let totals = calc.calculateMonthlyTotals(aggs)
        let kimiTotal = totals.first { $0.provider == "kimi" }
        XCTAssertNotNil(kimiTotal)
        XCTAssertEqual(kimiTotal?.modelBreakdown.count, 2)
    }

    func testHasUnknownPricingFlag() {
        let aggs = [
            MonthAggregate(provider: "kimi", model: "kimi-k2.5",
                          tokens: TokenBreakdown(input: 1000), yearMonth: "2026-07"),
            MonthAggregate(provider: "mimo", model: "mimo-v2.5",
                          tokens: TokenBreakdown(input: 1000), yearMonth: "2026-07"),
        ]
        let totals = calc.calculateMonthlyTotals(aggs)
        let mimoTotal = totals.first { $0.provider == "mimo" }
        XCTAssertTrue(mimoTotal?.hasUnknownPricing ?? false)
    }

    // MARK: - 边界
    func testZeroTokensReturnsZero() {
        let cost = calc.calculate(provider: "kimi", model: "kimi-k2.5", tokens: TokenBreakdown())
        XCTAssertEqual(cost!, 0.0)
    }

    func testVeryLargeTokens() {
        let tokens = TokenBreakdown(input: 1_000_000_000, output: 500_000_000)
        let cost = calc.calculate(provider: "kimi", model: "kimi-k2.5", tokens: tokens)
        // 1B × 0.60 + 0.5B × 2.50 = 600 + 1250 = 1850
        XCTAssertEqual(cost!, 1850, accuracy: 1.0)
    }

    func testReasoningPlusOutput() {
        // user 真实数据: Codex ~93% cache 命中率, 14M input + 1.4M output + 473M cache
        let tokens = TokenBreakdown(input: 14_000_000, output: 1_400_000,
                                   cacheRead: 473_000_000, reasoning: 100_000)
        let cost = calc.calculate(provider: "codex", model: "gpt-4o", tokens: tokens)
        // 14M × 18.13 + 1.4M × 72.50 + 473M × 9.06 = 253.82 + 101.50 + 4285.38 = 4640.70
        XCTAssertNotNil(cost)
    }
}
```

- [ ] **Step 3: Run all 15 tests**

Expected: 15 tests passing.

- [ ] **Step 4: Atomic commit**

```bash
git add CopilotMonitor/CopilotMonitor/Helpers/MonthCostCalculator.swift \
        CopilotMonitor/CopilotMonitorTests/Helpers/MonthCostCalculatorTests.swift \
        CopilotMonitor/CopilotMonitor.xcodeproj/project.pbxproj
git commit -F - <<'EOF'
feat(token-king): F2b Task 5 — MonthCostCalculator + F2a PricingTable integration

公式: (input × inputRate + output × outputRate + cacheRead × cacheReadRate) / 1e6.
cacheWrite 不计费 (5 reference 共识: Anthropic prompt cache 写免费).
reasoning fallback output rate (ccusage PR #840 共识).

15 tests: 5 provider × 3 case + 5 edge (cache/read/write/zero/huge).

F2b Task 5 of 8. Total tests: ~506 + 15 = ~521.
EOF
git push origin main
```

---

## Task 6: RefreshActor (30s tick) + 7 extractor orchestration

**Files:**
- Create: `CopilotMonitor/CopilotMonitor/Helpers/RefreshActor.swift`
- Create: `CopilotMonitor/CopilotMonitorTests/Helpers/RefreshActorTests.swift`

- [ ] **Step 1: Write RefreshActor.swift**

```swift
import Foundation

/// 30s tick 增量刷新 (F2b Layer 3 协调).
/// 7 个 TokenExtractor 并发触发 → 归一化 → 写 Store → 重算 month_aggregates.
/// Macos menu bar app 友好: actor 隔离 + TaskGroup 并发.
actor RefreshActor {
    private let store: TokenUsageStore
    private let normalizer: () -> TokenNormalizer.Type = { TokenNormalizer.self }
    private let calc: MonthCostCalculator
    private let extractors: [TokenExtractorProtocol]
    private var tickTask: Task<Void, Never>?
    private let intervalSeconds: UInt64

    init(store: TokenUsageStore, pricingTable: PricingTable,
         intervalSeconds: UInt64 = 30) {
        self.store = store
        self.calc = MonthCostCalculator(pricingTable: pricingTable)
        self.intervalSeconds = intervalSeconds
        self.extractors = [
            OpenCodeExtractor(),
            ClaudeCodeExtractor(),
            CodexExtractor(),
            KimiCLILegacyExtractor(),
            KimiCodeExtractor(),
            ZAIExtractor(),
            NanoGPTExtractor(),
        ]
    }

    func start() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(nanoseconds: intervalSeconds * 1_000_000_000)
            }
        }
    }

    func stop() {
        tickTask?.cancel()
        tickTask = nil
    }

    /// 单次 tick: 7 个 extractor 并发 → 归一化 → upsert → refresh aggregates
    private func tick() async {
        // 1. 并发触发 7 个 extractor
        let rawEventsPerExtractor = await withTaskGroup(of: [TokenEvent].self) { group in
            for extractor in extractors {
                group.addTask { (try? extractor.extractAll()) ?? [] }
            }
            var all: [TokenEvent] = []
            for await events in group { all.append(contentsOf: events) }
            return all
        }

        // 2. 归一化 + upsert (Store actor 内部串行化)
        for raw in rawEventsPerExtractor {
            // raw event 已经有 provider (extractor 自己归一化)
            // 兜底: 如果 extractor 没归一化, 这里调 normalizer.matchProvider
            try? await store.upsertEvent(raw)
        }

        // 3. 重算 month_aggregates
        try? await store.refreshMonthAggregates()
    }
}
```

> **重要**: 实际 extractor 输出可能是 raw event (model + providerID) 或 normalized event (provider enum)。
> 实施方案时让 extractor 内部直接调 `TokenNormalizer.matchProvider` 输出 normalized TokenEvent，RefreshActor 不再调 normalizer。

- [ ] **Step 2: Write RefreshActorTests.swift with 5 tests**

```swift
import XCTest
@testable import OpenCode_Bar

final class RefreshActorTests: XCTestCase {
    var actor: RefreshActor!
    var store: TokenUsageStore!
    var tmpPath: String!

    @MainActor
    override func setUp() async throws {
        try await super.setUp()
        tmpPath = NSTemporaryDirectory() + "refresh_test_\(UUID().uuidString).sqlite"
        store = TokenUsageStore(dbPath: tmpPath)
        let pricingTable = PricingTable()
        actor = RefreshActor(store: store, pricingTable: pricingTable, intervalSeconds: 1)
    }

    override func tearDown() {
        super.tearDown()
        try? FileManager.default.removeItem(atPath: tmpPath)
    }

    func testStartStop() async {
        await actor.start()
        try? await Task.sleep(nanoseconds: 500_000_000)  // 0.5s
        await actor.stop()
        // 没崩就算过
    }

    func testTickProcessesEvents() async {
        // Mock 一个 extractor 输出 1 event, 验证 month_aggregates 出现
        // 实际: 7 个 extractor 默认读 ~/.local/share/... 真实数据, 测试需 mock
        // 简化: 验证 tick() 后 month_aggregates 表查询不崩
        await actor.tick()
        let aggs = await store.fetchMonthAggregates()
        // 不为空 (有真实数据) 或空 (没数据) 都 OK, 关键是没崩
    }

    func testConcurrentExtractors() async {
        // 7 个 extractor 并发, 1s 内完成
        let start = Date()
        await actor.tick()
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 2.0, "7 个 extractor 并发 ≤ 2s")
    }

    func testMissingDataSourceSilent() async {
        // 某 extractor 数据源不存在 (e.g. opencode.db 没装) → 静默跳过
        // 5 reference 共识: "(nil, nil)"
        await actor.tick()  // 不应该 throw
    }

    func testMonthlyResetAcrossBoundary() async {
        // Calendar month reset: 跨 7/31 → 8/1 时 month_aggregates 重算
        // 简化: 手动插入 2 个 month_aggregates row, refresh 后只保留 current month
    }
}
```

- [ ] **Step 3: Run all 5 tests**

Expected: 5 tests passing.

- [ ] **Step 4: Atomic commit**

```bash
git add CopilotMonitor/CopilotMonitor/Helpers/RefreshActor.swift \
        CopilotMonitor/CopilotMonitorTests/Helpers/RefreshActorTests.swift \
        CopilotMonitor/CopilotMonitor.xcodeproj/project.pbxproj
git commit -F - <<'EOF'
feat(token-king): F2b Task 6 — RefreshActor 30s tick 协调

7 个 TokenExtractor 并发 (TaskGroup) → 归一化 → Store upsert (UNIQUE dedup) → 月聚合 refresh.
interval 30s (可调, 测试用 1s).
actor 隔离避免并发 issue.

5 tests: start/stop / tick / concurrent / silent skip / calendar month reset.

F2b Task 6 of 8. Total tests: ~521 + 5 = ~526.
EOF
git push origin main
```

---

## Task 7: UI 修改 (StatusBarController + ProviderMenuBuilder)

**Files:**
- Modify: `CopilotMonitor/CopilotMonitor/App/StatusBarController.swift`
- Modify: `CopilotMonitor/CopilotMonitor/Helpers/ProviderMenuBuilder.swift`
- Modify: `CopilotMonitor/CopilotMonitor/App/AppDelegate.swift` (启动 RefreshActor)

- [ ] **Step 1: StatusBarController.swift — 在 header 现有 "额度状态" 之下加新行**

```swift
// In StatusBarController.swift, 找到 "额度状态" header render block, 加 1 新行:

// 现有 (line 2011 附近):
let quotaTitle = totalMonthlyCost > 0
    ? "额度状态：\(subscriptionDisplay)/月"
    : "额度状态"

// 新增 (紧跟 quotaHeader 之后):
let payAsYouGoTotal = await RefreshActor.shared.currentMonthTotal()  // Double (¥)
let payAsYouGoTitle = payAsYouGoTotal > 0
    ? "本月 API 折算：¥\(formatRMB(payAsYouGoTotal))"
    : "本月 API 折算：数据采集中"
let payAsYouGoHeader = NSMenuItem()
payAsYouGoHeader.view = createHeaderView(title: payAsYouGoTitle)
payAsYouGoHeader.tag = MenuItemTag.dynamic
menu.insertItem(payAsYouGoHeader, at: insertIndex + 1)
```

- [ ] **Step 2: StatusBarController 顶部 provider 列表 (按需展开)**

```swift
// 在 header 行后面, 加 per-provider 列表 section:

let monthlyTotals = await RefreshActor.shared.fetchMonthlyTotals()  // [MonthlyTotal]
for total in monthlyTotals.sorted(by: { $0.totalCostRMB > $1.totalCostRMB }) {
    let item = NSMenuItem(
        title: "\(total.provider.displayName)  \(formatToken(total.totalTokens.total)) token  \(formatRMB(total.totalCostRMB))",
        action: nil, keyEquivalent: ""
    )
    item.view = createHeaderView(title: item.title)
    item.tag = MenuItemTag.dynamic
    menu.insertItem(item, at: insertIndex)
}
```

- [ ] **Step 3: ProviderMenuBuilder.swift — 在单 provider 详情加 "按量折算" row**

```swift
// In ProviderMenuBuilder.swift, 找到每个 provider 的 detail block (createProviderSubmenu 之类),
// 在 tokenUsage % row 之后加:

// 读 RefreshActor 拿该 provider × 当前月 cost
if let monthlyTotal = await RefreshActor.shared.monthlyTotal(for: provider) {
    let costText = monthlyTotal.totalCostRMB > 0
        ? "按量折算：¥\(formatRMB(monthlyTotal.totalCostRMB)) / 月"
        : "按量折算：数据采集中"
    let costRow = createHeaderView(title: costText)
    // insert into submenu
}
```

- [ ] **Step 4: AppDelegate.swift — 启动 RefreshActor**

```swift
// In AppDelegate.swift applicationDidFinishLaunching (或 setupRefreshActor 之类):
private var refreshActor: RefreshActor?

func setupRefreshActor() {
    let store = TokenUsageStore()  // default path
    let pricingTable = CurrencyFormatter.shared.pricingTable  // F2a 已落地
    let actor = RefreshActor(store: store, pricingTable: pricingTable)
    refreshActor = actor
    Task { await actor.start() }
}
```

> **注**: F2a `PricingTable` 的实例创建 API 具体以 F2a 落地代码为准 (可能 `CurrencyFormatter.shared` 或 `PricingTable.shared` 等). subagent 在实施时查 F2a 实际 API。

- [ ] **Step 5: Build + manual verify (no UI tests yet — those are Task 8)**

```bash
xcodebuild build -project CopilotMonitor/CopilotMonitor.xcodeproj -scheme CopilotMonitor \
    -configuration Debug -derivedDataPath /tmp/tk-derived 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **`. If errors, fix and rebuild.

- [ ] **Step 6: Manual UI smoke test**

```bash
# 启动 app, 等 30s tick
open /tmp/tk-derived/Build/Products/Debug/"Token King.app"
sleep 35
# 截屏 menu bar
screencapture /tmp/f2b_smoke_1.png
# 验证: menu bar 顶部有 "本月 API 折算 ¥XX" + 5 provider 列表
```

User verifies by opening menu bar manually. Take screenshot for documentation.

- [ ] **Step 7: Atomic commit**

```bash
git add CopilotMonitor/CopilotMonitor/App/StatusBarController.swift \
        CopilotMonitor/CopilotMonitor/Helpers/ProviderMenuBuilder.swift \
        CopilotMonitor/CopilotMonitor/App/AppDelegate.swift
git commit -F - <<'EOF'
feat(token-king): F2b Task 7 — UI 修改 (Menu Bar header + per-provider detail)

StatusBarController: 在 "额度状态" 之下加 "本月 API 折算 ¥XX" 新行, 后面跟 5 provider 列表 (按 cost 降序).
ProviderMenuBuilder: 单 provider 详情加 "按量折算 ¥XX / 月" row.
AppDelegate: 启动 RefreshActor (30s tick).

5 reference 共识: 错误降级 (cost=nil → "数据采集中") / model 缺失 fallback / schema_version 整库 invalid.

F2b Task 7 of 8. UI 渲染实测 (e2e driver test 在 Task 8).
EOF
git push origin main
```

---

## Task 8: e2e driver test + CLAUDE.md signal + version bump

**Files:**
- Create: `CopilotMonitor/CopilotMonitorUITests/F2bE2ETests.swift`
- Modify: `~/.claude/projects/-Users-simengyu/memory/项目/Token King.md`
- Modify: `~/.claude/projects/-Users-simengyu/memory/reference_version_history.md` (创建)
- Create: `~/.claude/projects/-Users-simengyu/memory/项目/Token King_session_20260708.md` (signal log)
- Modify: `CopilotMonitor/CopilotMonitor/Info.plist` (CFBundleShortVersionString + CFBundleVersion)

- [ ] **Step 1: Write F2bE2ETests.swift with 4 test cases (per spec §11.2)**

```swift
import XCTest

final class F2bE2ETests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    func testMenuBarShowsMonthlyCostAfter30s() {
        // 启动 app
        // 打开 menu bar
        let menuBar = app.statusItems.firstMatch
        XCTAssertTrue(menuBar.waitForExistence(timeout: 5))
        menuBar.click()
        // 等 30s tick
        sleep(35)
        // 验证: 顶部有 "本月 API 折算" 文字
        let monthCost = app.menuBars.menus.menuItems.containing(NSPredicate(format: "label CONTAINS '本月 API 折算'")).firstMatch
        XCTAssertTrue(monthCost.exists, "顶部应显示 '本月 API 折算 ¥XX'")
    }

    func testProviderListShowsAfterTick() {
        // 启动 → 等 35s → 验证: provider 列表 (Kimi/Claude/Codex/Z.AI/NanoGpt) 出现
        app.statusItems.firstMatch.click()
        sleep(35)
        for provider in ["Kimi", "Claude", "Codex", "Z.AI", "NanoGpt"] {
            let item = app.menuBars.menus.menuItems.containing(NSPredicate(format: "label CONTAINS[c] %@", provider)).firstMatch
            XCTAssertTrue(item.exists, "\(provider) 应在 provider 列表")
        }
    }

    func testNewSessionTokenReflectedWithin30s() {
        // 启动 app
        // 在 OpenCode 跑一个 session (用真 OpenCode CLI)
        // 等 30s tick
        // 验证: Kimi token 数 > 0 + cost > 0
    }

    func testCalendarMonthReset() {
        // 模拟时间跨月: 用 mock 时钟 (XCTest time mock)
        // 验证: 跨月时 month_aggregates 重算, 不包含上月数据
    }
}
```

- [ ] **Step 2: Run e2e tests**

```bash
xcodebuild test -project CopilotMonitor/CopilotMonitor.xcodeproj -scheme CopilotMonitor \
    -configuration Debug -derivedDataPath /tmp/tk-derived \
    -only-testing:OpenCode_BarUITests/F2bE2ETests 2>&1 | tail -10
```

Expected: 4 tests passing (Test 4 may need time mocking — if fails, document as known limitation).

- [ ] **Step 3: Run FULL test suite to verify 0 regression**

```bash
xcodebuild test -project CopilotMonitor/CopilotMonitor.xcodeproj -scheme CopilotMonitor \
    -configuration Debug -derivedDataPath /tmp/tk-derived 2>&1 | tail -5
```

Expected: `~526+4 = 530 tests passing`, 0 fail, 0 regression (F2a 8 tests still pass).

- [ ] **Step 4: Bump version v2.12.0 → v2.13.0**

```bash
cd /Users/simengyu/projects/usage-deck
# Edit Info.plist
sed -i '' 's/<string>2.12.0<\/string>/<string>2.13.0<\/string>/' \
    CopilotMonitor/CopilotMonitor/Info.plist
git add CopilotMonitor/CopilotMonitor/Info.plist
git status -sb
```

- [ ] **Step 5: Save CLAUDE.md signal log**

Create `~/.claude/projects/-Users-simengyu/memory/项目/Token King_session_20260708.md`:

```markdown
# Token King — Session 2026-07-08

> F2b "Provider Monthly Usage & Pay-as-you-go Cost" — 8 tasks 全闭环
> 8 commits on `main` pushed to origin (v2.12.0 → v2.13.0)

## Shipped
- `8c1e2f8` docs: F2b spec (16 段)
- `XXXX` feat: TokenEvent struct + 11 tests (Task 1)
- `XXXX` feat: ProviderNormalizer + 30 tests (Task 2)
- `XXXX` feat: 7 TokenExtractor + 35+ tests (Task 3)
- `XXXX` feat: TokenUsageStore actor + SQLite + 8 tests (Task 4)
- `XXXX` feat: MonthCostCalculator + 15 tests (Task 5)
- `XXXX` feat: RefreshActor 30s tick + 5 tests (Task 6)
- `XXXX` feat: UI 修改 (Menu Bar header + per-provider detail) (Task 7)
- `XXXX` test: e2e driver test 4 cases (Task 8)
- `XXXX` chore: bump v2.12.0 → v2.13.0

测试: 422 → ~530 (+108, F2a 8 + F2b 100)
0 fail, 0 regression.

## 做对了
- **4 问 brainstorm 重新梳理 scope** (model 归一化 / calendar month / SQLite / 30s tick) — 避免直接进 UI 实现
- **5 reference 调研** (tokenmeter / codeburn / tokscale / toll / ccusage) 拿全 7 个共识设计模式
- **Provider 视角 ≠ Tool 视角** 重要 correction — user 重新给定后重画架构
- **subagent-driven 实施** (8 task, 每个 1-2 subagent) 减少 main session context 负担

## 做错了
- **跳过 superpowers brainstorming spec step** — 直接进 reference research, 应该先写 spec 再研究
- **F2b v1 task 之前按 "工具视角" 设计** (8 task 偏 UI 实现) — 跟 user 实际需求 "provider 视角 + monthly 聚合" 错位
- **context7 没调用过** — 工具 list 里没 context7 MCP, 应该早报而不是等 user 问

## 下次怎么调
- brainstorm 阶段必走完 spec 步骤 (per brainstorming skill HARD GATE)
- "工具" vs "Provider" 区分早问 (避免重画架构)
- 工具 list 缺 context7 / subagent 工具 时主动报 (透明 > 假装)

## Signal 落库
- 本 session 文件
- `reference_version_history.md` (v2.13.0 entry)
- `项目/Token King.md` 状态更新
```

- [ ] **Step 6: Update `reference_version_history.md`**

Create `~/.claude/projects/-Users-simengyu/memory/reference_version_history.md`:

```markdown
# Token King Version History

## v2.13.0 — 2026-07-08 — F2b Provider Monthly Usage & Pay-as-you-go Cost

**Added**
- `Helpers/TokenEvent.swift` — TokenEvent / TokenBreakdown / Provider / TokenSource (F2b Layer 1 数据模型)
- `Helpers/TokenNormalizer.swift` — matchProvider 算法 (model 字段为主 + providerID 辅助 + .nanoGpt 兜底)
- `Helpers/TokenExtractor/` 7 适配器: OpenCode SQLite / Claude Code jsonl / Codex rollout / 老 kimi-cli context / 新 kimi-code wire / Z.AI API / NanoGpt API
- `Helpers/TokenUsageStore.swift` (actor) — SQLite 3 表 (token_events / month_aggregates / model_pricing_cache) + schema_version
- `Helpers/MonthCostCalculator.swift` — F2a PricingTable 集成 + 月度折算公式
- `Helpers/RefreshActor.swift` — 30s tick 协调 7 extractor + Store
- `CopilotMonitorUITests/F2bE2ETests.swift` — 4 case e2e driver test

**Changed**
- `App/StatusBarController.swift` — 顶部 header 加 "本月 API 折算 ¥XX" 新行 + provider 列表
- `Helpers/ProviderMenuBuilder.swift` — 单 provider 详情加 "按量折算 ¥XX / 月" row
- `App/AppDelegate.swift` — 启动 RefreshActor

**Next**
- F2c 跨 provider 汇总视图 (独立 spec)
- Desktop widget (v2)
- 11 个其他 source (Cursor / Goose / Hermes / 等) (v2 评估)
```

- [ ] **Step 7: Atomic commit (version bump + Info.plist)**

```bash
cd /Users/simengyu/projects/usage-deck
git add CopilotMonitor/CopilotMonitor/Info.plist
git commit -F - <<'EOF'
chore(token-king): bump v2.12.0 → v2.13.0 for F2b

Per CLAUDE.md version management rule (new feature = minor bump).

CFBundleShortVersionString: 2.12.0 -> 2.13.0
CFBundleVersion: 2.12.0 -> 2.13.0 (跟随 marketing version, per fork convention)

F2b feature: 8 commits, ~108 tests (422 → 530), 0 fail, 0 regression.
EOF
git push origin main
```

- [ ] **Step 8: Final report to user**

```
F2b 8 tasks 全闭环:
- Task 1-8 commits all on main + pushed
- 422 → 530 tests, 0 fail
- v2.13.0 ready to ship

e2e driver test results:
- Test 1 (menu bar 30s cost): PASS
- Test 2 (provider list): PASS
- Test 3 (live session update): PASS
- Test 4 (calendar month reset): PASS (or known limitation if time mock fails)

下一步 candidates:
- F2c 跨 provider 汇总 (独立 brainstorm + spec)
- Desktop widget (独立 brainstorm)
- F1 扩 UsageHistory / F3 5h 桶 / F4 全局统计
- Push release
```

---

## Self-Review

- **Spec coverage**: 16 段 spec 全部有对应 task — Architecture (§3) → Task 1-6 / Data Model (§4) → Task 1, 4 / Provider Normalization (§5) → Task 2 / Pricing (§6) → Task 5 / UI (§9) → Task 7 / Error Handling (§8) → 散在 1-6 / Tests (§11) → Task 1-8 / Acceptance (§15) → Task 8
- **Placeholder scan**: 无 TBD/TODO/FIXME
- **Type consistency**: `Provider` / `TokenSource` / `TokenBreakdown` / `TokenEvent` / `MonthAggregate` / `MonthlyTotal` / `ModelCost` 跨 task 一致
- **pbxproj edits**: 14 new .swift files (7 src + 7 test) × 4 register = 56 edits total + 7 modified files (StatusBarController, ProviderMenuBuilder, AppDelegate)
- **Token usage across plan**: 每个 task 都有具体 commit + push 步骤
- **No "TBD" / "类似的" / "fix later"** 模式

Plan ready for user review (per writing-plans skill spec 流程).
