# UI Fixes: Complete Menu Restructure with Pay-as-you-go & Quota Sections

## TL;DR

> **Quick Summary**: Complete UI overhaul - separate Pay-as-you-go (dollar) and Quota (percent) sections, add new providers (Antigravity, OpenCode Zen), implement daily history for all pay-as-you-go providers.
> 
> **Deliverables**:
> - Two distinct sections: Pay-as-you-go ($) and Quota Status (%)
> - New providers: Antigravity (local), OpenCode Zen (CLI)
> - Copilot split: Add-on (pay-as-you-go) + Free Quota (quota)
> - Daily usage history for OpenCode Zen and Copilot
> - Full detail submenus for all providers
> - 16x16 icons, Sign In/Reset Login removed
> 
> **Estimated Effort**: X-Large
> **Parallel Execution**: Partial (some tasks can run in parallel)

---

## Target Menu Structure

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Pay-as-you-go                          $322.81
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  🌐 OpenRouter         $37.42  ▸
      ├─ Credits: $131/$6,685 (2%)
      ├─ Daily: $0.00
      └─ Weekly: $0.00

  🚀 OpenCode Zen       $285.39  ▸
      ├─ Avg/Day: $9.51
      ├─ Sessions: 4,845
      ├─ Messages: 104,008
      ├─ ─────────────
      ├─ Top Models:
      │    ├─ gpt-5.2: $55.55
      │    ├─ gemini-3-flash: $25.99
      │    └─ gpt-5.2-codex: $1.30
      ├─ ─────────────
      └─ Usage History ▸
           ├─ Jan 30: $0.00
           ├─ Jan 29: $0.00
           └─ ...

  🐙 Copilot Add-on     $0.00  ▸
      ├─ Overage Requests: 0
      └─ Usage History ▸
           ├─ Jan 30: 0 overage ($0.00)
           ├─ Jan 29: 0 overage ($0.00)
           └─ ...

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Quota Status
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  🟣 Claude             78%  ▸
      ├─ 5h Window: 78%
      │    └─ Resets: 17:00
      ├─ 7d Window: 82%
      │    └─ Resets: Feb 5
      ├─ ─────────────
      ├─ Sonnet (7d): 90%
      ├─ Opus (7d): 100%
      └─ Extra Usage: OFF

  🤖 Codex              92%  ▸
      ├─ Primary: 92% (5h)
      ├─ Secondary: 92% (53h)
      ├─ ─────────────
      ├─ Plan: Pro
      └─ Credits: $0.00

  ✨ Gemini CLI         100%  ▸
      ├─ gemini-2.0-flash: 100%
      ├─ gemini-2.5-flash: 100%
      └─ gemini-2.5-pro: 100%

  🔮 Antigravity        80%  ▸
      ├─ Gemini 3 Pro (High): 100%
      ├─ Gemini 3 Pro (Low): 100%
      ├─ Gemini 3 Flash: 100%
      ├─ Claude Sonnet 4.5: 80%
      ├─ Claude Opus 4.5: 80%
      ├─ ─────────────
      ├─ Plan: Free
      └─ Email: kars@kargn.as

  🐙 Copilot            65%  ▸
      ├─ [═══════░░░] 350/1000
      ├─ This Month: 650 used
      └─ Free Quota: 1000

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

---

## Context

### Original Request
1. 모든 프로바이더가 비활성화 상태로 보이고 디테일 서브메뉴가 없음
2. 아이콘이 너무 큼
3. Usage Status가 Copilot 전용인데 최상위 메뉴에 분리되어 있음

### Additional Requirements (User Feedback)
1. **Pay-as-you-go vs Quota 분리**: 
   - Pay-as-you-go → 달러($) 표시
   - Quota → 퍼센트(%) 표시
2. **Copilot 두 섹션에 분리 표시**:
   - Pay-as-you-go: Copilot Add-on (초과 사용 금액)
   - Quota Status: Copilot 무료 할당량
3. **OpenCode Zen 추가**: CLI `opencode stats` 파싱
4. **Antigravity 추가**: 로컬 language server API
5. **Daily History**:
   - OpenCode Zen: `opencode stats --days N` 누적 차이 계산
   - Copilot: `/settings/billing/copilot_usage_table` API (Swift 네이티브)
6. **메뉴바 아이콘**: Pay-as-you-go 합계 달러 표시

---

## Copilot Data Semantics (IMPORTANT)

**Current CopilotUsage Model** (`Models/CopilotUsage.swift`):
```swift
struct CopilotUsage: Codable {
    let netBilledAmount: Double      // Overage cost in $
    let netQuantity: Double          // Billed (overage) request count
    let discountQuantity: Double     // Free tier usage
    let userPremiumRequestEntitlement: Int  // Monthly limit
    
    var usedRequests: Int { return Int(discountQuantity) }  // ⚠️ Only free tier!
    var limitRequests: Int { return userPremiumRequestEntitlement }
}
```

**CRITICAL**: Current `usedRequests` only counts `discountQuantity` (free tier usage).
Total actual requests = `discountQuantity` + `netQuantity` (free + overage).

**Data Flow Mapping**:

| Display Location | Data Source | Formula |
|------------------|-------------|---------|
| Quota Status "Copilot XX%" | `remaining / entitlement * 100` | `(entitlement - discountQuantity) / entitlement * 100` |
| Pay-as-you-go "Copilot Add-on $X.XX" | `netBilledAmount` | Direct value |
| Quota submenu "This Month: X used" | Total used | `discountQuantity + netQuantity` (consider fixing `usedRequests`) |
| Status bar icon | Various | See Task 10 |

**History API (DailyUsage) Mapping**:

From `/copilot_usage_table` response:
| Response Field | DailyUsage Field | Notes |
|----------------|------------------|-------|
| `cells[0].value` | `date` | Parse "Jan 29" to Date |
| `cells[1].value` | `requests` | Total included (free) |
| `cells[2].value` | `overageRequests` | Billed (overage) |
| `cells[4].value` | `cost` | Parse "$0.35" to Double |

**Potential Fix**: Update `usedRequests` to include overage:
```swift
var usedRequests: Int { return Int(discountQuantity + netQuantity) }
```
But this may break existing predictions. Evaluate in Task 8.

---

## "Usage History" Menu Decision

**Current State**: Top-level "Usage History" menu exists at line ~493-504 in `StatusBarController.swift`.
This is the anchor point for `updateMultiProviderMenu()`.

**Decision**: KEEP top-level "Usage History" (for Copilot)
- It shows daily predictions and is Copilot-specific
- Per-provider history goes into SUBMENUS under each provider

**Final Menu Structure**:
```
[Copilot Usage View]  ← Existing, keep
Usage History ▸        ← Existing, keep (Copilot-specific predictions)
───────────────
Pay-as-you-go          $322.81
  OpenRouter           $37.42 ▸
  OpenCode Zen         $285.39 ▸
      └─ Usage History ▸   ← NEW: Per-provider history in submenu
  Copilot Add-on       $0.00 ▸
      └─ Usage History ▸
───────────────
Quota Status
  Claude               78% ▸
  Codex                92% ▸
  ...
```

---

## Research Findings

### API Endpoints & Data Sources

| Provider | Type | Data Source | Key Fields |
|----------|------|-------------|------------|
| **OpenRouter** | Pay-as-you-go | `/api/v1/key`, `/api/v1/credits` | usage_monthly, total_credits, remaining |
| **OpenCode Zen** | Pay-as-you-go | CLI `opencode stats --days N` | Total Cost, Avg/Day, model breakdown |
| **Copilot Add-on** | Pay-as-you-go | `/copilot_usage_card`, `/copilot_usage_table` | netBilledAmount, billed_requests |
| **Claude** | Quota | `/api/oauth/usage` | five_hour, seven_day, sonnet, opus |
| **Codex** | Quota | `/backend-api/wham/usage` | primary_window, secondary_window, plan_type |
| **Gemini CLI** | Quota | `/v1internal:retrieveUserQuota` | buckets[].modelId, remainingFraction |
| **Antigravity** | Quota | Local Language Server | models[].label, remaining, plan |
| **Copilot** | Quota | `/copilot_usage_card` | discountQuantity, userPremiumRequestEntitlement |

### Copilot History API (from `github_copilot_history.py`)

**Endpoint**: `GET /settings/billing/copilot_usage_table?customer_id={id}&group=0&period=3&page={page}`

**Response Structure**:
```json
{
  "table": {
    "rows": [
      {
        "cells": [
          {"value": "Jan 29"},      // date
          {"value": "45"},          // included_requests
          {"value": "5"},           // billed_requests (overage)
          {"value": "$0.35"},       // gross_amount
          {"value": "$0.35"}        // billed_amount
        ],
        "subtable": {
          "rows": [
            {
              "cells": [
                {"value": "gpt-4o"},
                {"value": "30"},
                {"value": "5"},
                {"value": "$0.35"},
                {"value": "$0.35"}
              ]
            }
          ]
        }
      }
    ]
  }
}
```

### OpenCode Zen Stats (CLI)

**Command**: `opencode stats --days N --models 10`

**Output Parsing**:
- Total Cost: $285.39
- Avg Cost/Day: $9.51
- Sessions: 4,845
- Per-model costs

**Daily History Calculation**:
```
Day 7 ($4.38) - Day 6 ($0.19) = Jan 24: $4.19
Day 6 ($0.19) - Day 5 ($0.19) = Jan 25: $0.00
...
```

### Antigravity Local API

**Process**: `language_server_macos` (Antigravity app)
**Endpoint**: `POST /exa.language_server_pb.LanguageServerService/GetUserStatus`
**Auth**: CSRF token from process args

**Response**:
```json
{
  "email": "user@example.com",
  "plan": "Free",
  "models": [
    {"label": "Gemini 3 Pro (High)", "remaining": "100%"},
    {"label": "Claude Sonnet 4.5", "remaining": "80%"}
  ]
}
```

---

## Work Objectives

### Core Objective
메뉴를 Pay-as-you-go (달러)와 Quota Status (퍼센트)로 분리하고, 새 프로바이더(Antigravity, OpenCode Zen)를 추가하며, 모든 프로바이더에 상세 서브메뉴를 구현한다.

### Concrete Deliverables
- New `ProviderIdentifier` cases: `.antigravity`, `.openCodeZen`, `.copilotAddon`
- New providers: `AntigravityProvider.swift`, `OpenCodeZenProvider.swift`
- Copilot split: Add-on (pay-as-you-go) + Quota (free)
- Copilot History API: Swift native `/copilot_usage_table` parsing
- OpenCode Zen History: CLI parsing with cumulative diff
- Menu restructure: Two sections with total sum header

### Definition of Done
- [ ] Menu bar shows Pay-as-you-go total ($322.81)
- [ ] Pay-as-you-go section: OpenRouter, OpenCode Zen, Copilot Add-on
- [ ] Quota Status section: Claude, Codex, Gemini CLI, Antigravity, Copilot
- [ ] All providers have detail submenus
- [ ] OpenCode Zen shows daily history
- [ ] Copilot shows daily history with model breakdown
- [ ] All icons 16x16
- [ ] Sign In/Reset Login removed
- [ ] Build succeeds

---

## Verification Strategy

### Build Command
```bash
pkill -x OpencodeProvidersMonitor || true
xcodebuild -project CopilotMonitor/CopilotMonitor.xcodeproj -scheme CopilotMonitor -configuration Debug build 2>&1 | grep -E "(error:|BUILD)"
open ~/Library/Developer/Xcode/DerivedData/CopilotMonitor-*/Build/Products/Debug/*.app
```

### Manual Verification
- Menu bar displays total pay-as-you-go cost
- Each provider shows correct data in submenu
- Daily history loads correctly
- No grayed-out menu items

---

## Execution Strategy

### Parallel Execution Waves

```
Wave 1 (Start Immediately):
└── Task 1: Extend Models (ProviderIdentifier + DetailedUsage)
    No dependencies - foundation for all other tasks

Wave 2 (After Wave 1 - Parallel):
├── Task 2: AntigravityProvider [depends: 1]
├── Task 3: OpenCodeZenProvider [depends: 1]
├── Task 4: Update ClaudeProvider [depends: 1]
├── Task 5: Update CodexProvider [depends: 1]
├── Task 6: Update GeminiCLIProvider [depends: 1]
└── Task 9: Update OpenRouterProvider [depends: 1]

Wave 3 (After Wave 2 - Sequential):
└── Task 7: Browser Cookie + Copilot History API [depends: 1]
    Complex task, should run alone

Wave 4 (After Wave 3):
└── Task 8: Split Copilot [depends: 7]
    Requires history service from Task 7

Wave 5 (After Wave 2, 4 - Can Parallelize):
├── Task 10: Menu Restructure [depends: 2,3,4,5,6,8,9]
└── Task 11: Detail Submenus [depends: 2,3,4,5,6,8,9]

Wave 6 (Final):
└── Task 12: Icon Resizing + Cleanup [depends: 10,11]
```

### Dependency Matrix

| Task | Depends On | Blocks | Can Parallelize With |
|------|------------|--------|---------------------|
| 1 | None | 2,3,4,5,6,7,9 | None (start immediately) |
| 2 | 1 | 10,11 | 3,4,5,6,9 |
| 3 | 1 | 10,11 | 2,4,5,6,9 |
| 4 | 1 | 10,11 | 2,3,5,6,9 |
| 5 | 1 | 10,11 | 2,3,4,6,9 |
| 6 | 1 | 10,11 | 2,3,4,5,9 |
| 7 | 1 | 8 | None (complex, run alone) |
| 8 | 7 | 10,11 | None |
| 9 | 1 | 10,11 | 2,3,4,5,6 |
| 10 | 2,3,4,5,6,8,9 | 12 | 11 |
| 11 | 2,3,4,5,6,8,9 | 12 | 10 |
| 12 | 10,11 | None | None (final) |

### Critical Path

```
Task 1 → Task 7 → Task 8 → Task 10 → Task 12
      ↘ Task 2,3,4,5,6,9 → Task 11 ↗
```

**Estimated Speedup**: ~35% faster with parallel execution vs sequential

---

## TODOs

- [x] 1. Extend Models (ProviderIdentifier + DetailedUsage + ProviderUsage)

  **What to do**:
  
  ---
  
  **1a. Add new `ProviderIdentifier` cases**:
  
  File: `CopilotMonitor/CopilotMonitor/Models/ProviderProtocol.swift`
  
  Add:
  - `.antigravity` - Antigravity local language server
  - `.openCodeZen` - OpenCode CLI stats
  
  **NOTE**: Do NOT add `.copilotAddon` - Copilot Add-on is a UI-only display of existing `CopilotUsage.netBilledAmount` (see Task 8)

  Also add `iconName` computed property if missing:
  ```swift
  var iconName: String {
      switch self {
      case .copilot: return "CopilotIcon"
      case .claude: return "ClaudeIcon"
      case .codex: return "CodexIcon"
      case .geminiCLI: return "GeminiIcon"
      case .openRouter: return "OpencodeIcon"  // or create new
      case .antigravity: return "AntigravityIcon"
      case .openCodeZen: return "OpencodeIcon"
      // etc.
      }
  }
  ```

  ---

  **1b. Extend `ProviderUsage` enum for dollar display** (CRITICAL for Pay-as-you-go $ display)
  
  File: `CopilotMonitor/CopilotMonitor/Models/ProviderUsage.swift`
  
  **Current**:
  ```swift
  case payAsYouGo(utilization: Double, resetsAt: Date?)
  ```
  
  **CHANGE TO** (add `cost` parameter):
  ```swift
  case payAsYouGo(utilization: Double, cost: Double?, resetsAt: Date?)
  ```
  
  **Why**: The current model only stores utilization (%), but we need dollar amounts for:
  - OpenRouter: `usage_monthly` ($37.42)
  - OpenCode Zen: total cost ($285.39)
  - Menu header total: sum of all pay-as-you-go costs
  
  **Update sites**:
  - All `.payAsYouGo(utilization:, resetsAt:)` → `.payAsYouGo(utilization:, cost:, resetsAt:)`
  - Add `cost` computed property to ProviderUsage
  - Update Codable encode/decode

  ---

  **1c. Extend `DetailedUsage` struct** with new fields:
  
  File: `CopilotMonitor/CopilotMonitor/Models/ProviderResult.swift`
  
  Add fields:
  - `fiveHourUsage: Double?`, `fiveHourReset: Date?` - Claude 5h
  - `sevenDayUsage: Double?`, `sevenDayReset: Date?` - Claude 7d
  - `sonnetUsage: Double?`, `opusUsage: Double?` - Claude model breakdown
  - `modelBreakdown: [String: Double]?` - Per-model usage (Gemini, Antigravity)
  - `secondaryUsage: Double?`, `secondaryReset: Date?`, `primaryReset: Date?` - Codex
  - `creditsBalance: Double?`, `planType: String?` - Codex/Antigravity
  - `extraUsageEnabled: Bool?` - Claude
  - `sessions: Int?`, `messages: Int?`, `avgCostPerDay: Double?` - OpenCode Zen
  - `email: String?` - Antigravity
  - `dailyHistory: [DailyUsage]?` - For history display
  - `monthlyCost: Double?` - OpenRouter/OpenCode Zen (for submenu)
  - `creditsRemaining: Double?`, `creditsTotal: Double?` - OpenRouter

  ---

  **1d. REUSE existing `DailyUsage` struct (DO NOT create new)**:
  
  **Existing Type**: `CopilotMonitor/CopilotMonitor/Models/UsageHistory.swift`
  
  ```swift
  // ALREADY EXISTS - DO NOT DUPLICATE
  struct DailyUsage: Codable {
      let date: Date              // UTC date
      let includedRequests: Double // Included requests
      let billedRequests: Double   // Add-on billed requests
      let grossAmount: Double      // Gross amount
      let billedAmount: Double     // Add-on billed amount
      
      var totalRequests: Double { includedRequests + billedRequests }
  }
  ```
  
  **For OpenCode Zen daily costs**: Use `DetailedUsage.dailyHistory: [DailyUsage]?`
  - Set `includedRequests = 0`, `billedRequests = 0`
  - Set `billedAmount = dailyCost`
  - This reuses existing type without collision

  ---

  **References**:
  - `CopilotMonitor/CopilotMonitor/Models/ProviderResult.swift` - DetailedUsage struct
  - `CopilotMonitor/CopilotMonitor/Models/ProviderUsage.swift` - ProviderUsage enum
  - `CopilotMonitor/CopilotMonitor/Models/ProviderProtocol.swift` - ProviderIdentifier enum

  **Integration Points** (files that must be updated after this task):
  - `CopilotMonitor/CopilotMonitor/Services/ProviderManager.swift:21-27` - register new providers (Task 2, 3)
  - `CopilotMonitor/CopilotMonitor/App/StatusBarController.swift` - `iconForProvider()`, `isProviderEnabled()`
  - All provider files - update `.payAsYouGo()` calls to include `cost:` parameter

  **Downstream Compile-Fix Sites** (adding new fields to DetailedUsage):
  - All `ProviderResult(usage:, details:)` call sites must be updated
  - `createDetailSubmenu()` in StatusBarController must handle new fields

  **Acceptance Criteria**:
  ```bash
  # 1. Build succeeds
  xcodebuild -project CopilotMonitor/CopilotMonitor.xcodeproj -scheme CopilotMonitor -configuration Debug build 2>&1 | grep "BUILD SUCCEEDED"
  
  # 2. ProviderUsage.payAsYouGo has cost parameter
  grep -q "case payAsYouGo.*cost:" CopilotMonitor/CopilotMonitor/Models/ProviderUsage.swift
  
  # 3. New ProviderIdentifier cases exist
  grep -q "antigravity" CopilotMonitor/CopilotMonitor/Models/ProviderProtocol.swift
  grep -q "openCodeZen" CopilotMonitor/CopilotMonitor/Models/ProviderProtocol.swift
  
  # 4. NO copilotAddon identifier (it's UI-only, not a provider)
  ! grep -q "copilotAddon" CopilotMonitor/CopilotMonitor/Models/ProviderProtocol.swift
  ```

  **Commit**: YES
  - Message: `feat(model): add cost to payAsYouGo, new provider identifiers, extend DetailedUsage`
  - Files: `Models/ProviderResult.swift`, `Models/ProviderProtocol.swift`, `Models/ProviderUsage.swift`

---

- [ ] 2. Create AntigravityProvider

  **What to do**:
  - Create new `AntigravityProvider.swift` in `CopilotMonitor/CopilotMonitor/Providers/`
  - Detect `language_server_macos` process and extract CSRF token
  - Find listening ports via `lsof`
  - Call `/exa.language_server_pb.LanguageServerService/GetUserStatus`
  - Parse response: email, plan, models with quotas
  - Return quota-based usage (minimum of all model remaining%)

  **API Details**:
  ```swift
  // 1. Find process: ps -ax | grep language_server_macos | grep antigravity
  // 2. Extract CSRF: --csrf_token=XXX from process args
  // 3. Find port: lsof -nP -iTCP -sTCP:LISTEN -a -p PID
  // 4. POST to https://127.0.0.1:{port}/exa.language_server_pb.LanguageServerService/GetUserStatus
  // Headers: X-Codeium-Csrf-Token, Connect-Protocol-Version: 1
  // Body: {"metadata":{"ideName":"antigravity",...}}
  ```

  **References**:
  - `scripts/query-antigravity-local.sh` - Complete implementation reference

  **Provider Registration** (MUST update after creating provider):
  
  File: `CopilotMonitor/CopilotMonitor/Services/ProviderManager.swift:20-28`
  
  Add `AntigravityProvider()` to the providers array:
  ```swift
  private func registerDefaultProviders() {
      providers = [
          ClaudeProvider(),
          CodexProvider(),
          GeminiCLIProvider(),
          OpenRouterProvider(),
          OpenCodeProvider(),
          AntigravityProvider()  // ← ADD THIS LINE
      ]
  }
  ```

  **Acceptance Criteria**:
  ```bash
  # 1. Build succeeds
  xcodebuild -project CopilotMonitor/CopilotMonitor.xcodeproj -scheme CopilotMonitor -configuration Debug build 2>&1 | grep "BUILD SUCCEEDED"
  
  # 2. Provider registered (verify in code)
  grep -q "AntigravityProvider()" CopilotMonitor/CopilotMonitor/Services/ProviderManager.swift
  
  # 3. When Antigravity is running: menu shows model quotas
  # 4. When Antigravity is NOT running: menu shows "Antigravity: Not running" (graceful failure)
  ```

  **Commit**: YES
  - Message: `feat(provider): add AntigravityProvider for local language server`
  - Files: `Providers/AntigravityProvider.swift`, `Services/ProviderManager.swift`

---

- [ ] 3. Create OpenCodeZenProvider

  **What to do**:
  - Create new `OpenCodeZenProvider.swift` in `CopilotMonitor/CopilotMonitor/Providers/`
  - Execute CLI: `~/.opencode/bin/opencode stats --days 30 --models 10`
  - Parse output using regex:
    - Total Cost: `│Total Cost\s+\$([0-9.]+)`
    - Avg Cost/Day: `│Avg Cost/Day\s+\$([0-9.]+)`
    - Sessions: `│Sessions\s+([0-9,]+)`
    - Messages: `│Messages\s+([0-9,]+)`
    - Model costs: `│ (\S+)\s+.*│\s+Cost\s+\$([0-9.]+)`
  - Calculate daily history by running `opencode stats --days N` for N=1..7 and computing differences
  - Return pay-as-you-go usage with monthly cost

  **Daily History Calculation**:
  ```swift
  func calculateDailyHistory() async -> [DailyUsage] {
      var history: [DailyUsage] = []
      var previousCost = 0.0
      
      for day in (1...7).reversed() {
          let stats = await runOpenCodeStats(days: day)
          let dailyCost = stats.totalCost - previousCost
          history.append(DailyUsage(
              date: Calendar.current.date(byAdding: .day, value: -(day-1), to: Date())!,
              cost: dailyCost
          ))
          previousCost = stats.totalCost
      }
      return history.reversed()
  }
  ```

  **References**:
  - `scripts/query-opencode.sh` - CLI usage
  - `~/.opencode/bin/opencode stats --help` - CLI options

  **Provider Registration** (MUST update after creating provider):
  
  File: `CopilotMonitor/CopilotMonitor/Services/ProviderManager.swift:20-28`
  
  Add `OpenCodeZenProvider()` to the providers array:
  ```swift
  private func registerDefaultProviders() {
      providers = [
          ClaudeProvider(),
          CodexProvider(),
          GeminiCLIProvider(),
          OpenRouterProvider(),
          OpenCodeProvider(),
          AntigravityProvider(),
          OpenCodeZenProvider()  // ← ADD THIS LINE
      ]
  }
  ```

  **NOTE**: `OpenCodeProvider` (existing) ≠ `OpenCodeZenProvider` (new)
  - `OpenCodeProvider`: Uses opencode auth tokens for API access
  - `OpenCodeZenProvider`: Uses `opencode stats` CLI for cost tracking

  **Acceptance Criteria**:
  ```bash
  # 1. Build succeeds
  xcodebuild -project CopilotMonitor/CopilotMonitor.xcodeproj -scheme CopilotMonitor -configuration Debug build 2>&1 | grep "BUILD SUCCEEDED"
  
  # 2. Provider registered (verify in code)
  grep -q "OpenCodeZenProvider()" CopilotMonitor/CopilotMonitor/Services/ProviderManager.swift
  
  # 3. When opencode CLI exists: menu shows cost data
  # Expected: "OpenCode Zen    $285.39 ▸" with submenu showing daily breakdown
  
  # 4. When opencode CLI NOT found: graceful failure
  # Expected: Provider returns error, menu doesn't crash
  ```

  **Commit**: YES
  - Message: `feat(provider): add OpenCodeZenProvider with daily history`
  - Files: `Providers/OpenCodeZenProvider.swift`, `Services/ProviderManager.swift`

---

- [x] 4. Update ClaudeProvider with Full Data

  **What to do**:
  - Update `ClaudeUsageResponse` to include all fields:
    - `five_hour: UsageWindow?`
    - `seven_day_sonnet: UsageWindow?`
    - `seven_day_opus: UsageWindow?`
    - `extra_usage: ExtraUsage?`
  - Populate DetailedUsage with all fields

  **References**:
  - `CopilotMonitor/CopilotMonitor/Providers/ClaudeProvider.swift`
  - `scripts/query-claude.sh:33-42`

  **Acceptance Criteria**:
  ```bash
  # 1. Build succeeds
  xcodebuild -project CopilotMonitor/CopilotMonitor.xcodeproj -scheme CopilotMonitor -configuration Debug build 2>&1 | grep "BUILD SUCCEEDED"
  
  # 2. DetailedUsage populated (verify in debugger or menu):
  # - fiveHourUsage: percentage (0-100)
  # - fiveHourReset: Date
  # - sevenDayUsage: percentage (0-100)  
  # - sevenDayReset: Date
  # - sonnetUsage: percentage (0-100)
  # - opusUsage: percentage (0-100)
  # - extraUsageEnabled: Bool
  ```

  **Commit**: YES
  - Message: `feat(claude): add 5h/7d/Sonnet/Opus to DetailedUsage`
  - Files: `ClaudeProvider.swift`

---

- [ ] 5. Update CodexProvider with Full Data

  **What to do**:
  - Parse all fields: plan_type, secondary_window, credits
  - Populate DetailedUsage

  **References**:
  - `CopilotMonitor/CopilotMonitor/Providers/CodexProvider.swift`
  - `scripts/query-codex.sh:37-46`

  **Acceptance Criteria**:
  ```bash
  # 1. Build succeeds
  xcodebuild -project CopilotMonitor/CopilotMonitor.xcodeproj -scheme CopilotMonitor -configuration Debug build 2>&1 | grep "BUILD SUCCEEDED"
  
  # 2. DetailedUsage populated (verify in debugger or menu):
  # - primaryUsage: percentage (0-100)
  # - primaryReset: Date (5h window)
  # - secondaryUsage: percentage (0-100)
  # - secondaryReset: Date (53h window)
  # - planType: String ("Pro", "Free", etc.)
  # - creditsBalance: Double
  ```

  **Commit**: YES
  - Message: `feat(codex): add plan/secondary/credits to DetailedUsage`
  - Files: `CodexProvider.swift`

---

- [ ] 6. Update GeminiCLIProvider with Full Data

  **What to do**:
  - Return all model quotas in `modelBreakdown`
  - Keep minimum for main display

  **References**:
  - `CopilotMonitor/CopilotMonitor/Providers/GeminiCLIProvider.swift`
  - `scripts/query-gemini-cli.sh:47-54`

  **Acceptance Criteria**:
  ```bash
  # 1. Build succeeds
  xcodebuild -project CopilotMonitor/CopilotMonitor.xcodeproj -scheme CopilotMonitor -configuration Debug build 2>&1 | grep "BUILD SUCCEEDED"
  
  # 2. DetailedUsage.modelBreakdown populated:
  # Expected format: ["gemini-2.0-flash": 100.0, "gemini-2.5-flash": 100.0, "gemini-2.5-pro": 100.0]
  # Values are percentages (0-100)
  
  # 3. Main display shows MINIMUM of all models
  # If gemini-2.5-pro is at 80%, main shows "Gemini CLI 80%"
  ```

  **Commit**: YES
  - Message: `feat(gemini): add per-model quota to DetailedUsage`
  - Files: `GeminiCLIProvider.swift`

---

- [ ] 7. Implement Browser Cookie Extraction + Copilot History API (Swift Native)

  **Overview**:
  This is a complex task requiring two components:
  1. **BrowserCookieService**: Extract GitHub cookies from Chromium browsers
  2. **CopilotHistoryService**: Use cookies to call GitHub History API

  ---

  **ARCHITECTURAL CLARIFICATION: REPLACE WebView History with Cookie-based**

  **Current Implementation** (TO BE REPLACED):
  - Method: `fetchUsageHistoryNow()` in `StatusBarController.swift` (line ~1294-1380)
  - Uses: WebView JS fetch for `/copilot_usage_table`
  - Limitation: Tied to WebView lifecycle, can't be called independently
  - Date parsing: `cells[0]["sortValue"]` (ISO format)

  **New Architecture** (Cookie-based):
  ```
  BrowserCookieService
       │
       ▼
  Extract GitHub cookies from Chrome/Brave/Arc/Edge
       │
       ▼
  CopilotHistoryService
       │
       ├─► Fetch /settings/billing with cookies → Extract customerId
       │
       └─► Fetch /copilot_usage_table with cookies → Parse history
            │
            ▼
       [DailyUsage] with model breakdown
  ```

  **Migration Plan**:
  1. **CREATE**: `BrowserCookieService.swift` - Cookie extraction
  2. **CREATE**: `CopilotHistoryService.swift` - History API calls
  3. **DEPRECATE**: `fetchUsageHistoryNow()` in StatusBarController
  4. **REPLACE**: History fetch calls with CopilotHistoryService

  **Why Cookie-based?**
  - Independent of WebView lifecycle
  - Can fetch history even when WebView not loaded
  - Enables model breakdown parsing (subtable)
  - More flexible pagination

  **Code to Remove/Replace** (`StatusBarController.swift`):
  - `fetchUsageHistoryNow()` method (line ~1294-1380) → Replace with CopilotHistoryService call
  - `historyFetchTimer` logic → Keep timer, change target
  - WebView-based history JS fetch → Remove

  ---

  **7-PREREQUISITE: customer_id Acquisition**

  **The History API requires `customer_id`.** This is already implemented in `CopilotProvider.swift` and must be reused:

  **Existing Logic** (`CopilotProvider.swift:127-163`):
  ```swift
  // Method 1: DOM extraction via JavaScript
  if (data && data.payload && data.payload.customer && data.payload.customer.customerId) {
      return data.payload.customer.customerId.toString();
  }
  
  // Method 2: HTML regex patterns (fallback)
  let patterns = [
      #"customerId":(\d+)"#,
      #"customerId&quot;:(\d+)"#,
      #"customer_id=(\d+)"#
  ]
  ```

  **Source Page**: `https://github.com/settings/billing`
  - The page HTML contains `"customerId":12345678` in embedded JSON
  - Existing WebView already navigates here during Copilot auth

  **Integration for CopilotHistoryService**:
  ```swift
  class CopilotHistoryService {
      // Reuse customer_id from CopilotProvider or extract from cookies page
      func fetchHistory(cookies: GitHubCookies) async throws -> [DailyUsage] {
          // Step 1: Get customer_id by fetching billing page with cookies
          let customerId = try await fetchCustomerId(cookies: cookies)
          
          // Step 2: Call history API
          let url = "https://github.com/settings/billing/copilot_usage_table?customer_id=\(customerId)&group=0&period=3&page=1"
          // ...
      }
      
      private func fetchCustomerId(cookies: GitHubCookies) async throws -> String {
          let url = URL(string: "https://github.com/settings/billing")!
          var request = URLRequest(url: url)
          request.setValue(cookies.cookieHeader, forHTTPHeaderField: "Cookie")
          
          let (data, _) = try await URLSession.shared.data(for: request)
          let html = String(data: data, encoding: .utf8) ?? ""
          
          // Regex: "customerId":(\d+)
          let regex = try NSRegularExpression(pattern: #""customerId":(\d+)"#)
          if let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
             let range = Range(match.range(at: 1), in: html) {
              return String(html[range])
          }
          throw CopilotHistoryError.customerIdNotFound
      }
  }
  ```

  **Alternative**: If WebView-based CopilotProvider already has `customer_id`, pass it to CopilotHistoryService:
  - Store `customer_id` in `CopilotProvider` as instance property
  - Expose via public getter for CopilotHistoryService to use

  ---

  **7a. BrowserCookieService (New File)**

  **What to do**:
  - Create `Services/BrowserCookieService.swift`
  - Support Chromium-based browsers: Chrome, Brave, Arc, Edge
  - Extract cookies from SQLite database
  - Decrypt using macOS Keychain encryption key

  **Implementation Steps**:

  1. **Find Browser Cookie DB**:
     ```swift
     // Chrome: ~/Library/Application Support/Google/Chrome/Default/Cookies
     // Brave: ~/Library/Application Support/BraveSoftware/Brave-Browser/Default/Cookies
     // Arc: ~/Library/Application Support/Arc/User Data/Default/Cookies
     // Edge: ~/Library/Application Support/Microsoft Edge/Default/Cookies
     ```

  2. **Get Encryption Key from Keychain**:
     ```swift
     // Use Security.framework
     let query: [String: Any] = [
         kSecClass: kSecClassGenericPassword,
         kSecAttrService: "Chrome Safe Storage",  // or "Brave Safe Storage", etc.
         kSecAttrAccount: "Chrome",               // or "Brave", etc.
         kSecReturnData: true
     ]
     var result: AnyObject?
     SecItemCopyMatching(query as CFDictionary, &result)
     let password = String(data: result as! Data, encoding: .utf8)!
     ```

  3. **Derive AES Key using PBKDF2**:

      **CommonCrypto Integration** (REQUIRED FIRST):
      
      CommonCrypto is a C framework built into macOS. To use in Swift:
      
      **Option A (RECOMMENDED)**: Import via module map (no bridging header needed)
      ```swift
      // This works in modern Swift/Xcode (Swift 4.2+):
      import CommonCrypto
      ```
      
      **Option B**: If Option A fails, create bridging header
      1. Create `BrowserCookieService-Bridging-Header.h`:
         ```objc
         #import <CommonCrypto/CommonCrypto.h>
         ```
      2. Add to Xcode Build Settings: `Objective-C Bridging Header`
      
      **Verification** (before implementing):
      ```swift
      // Test if CommonCrypto is available
      import CommonCrypto
      let _ = kCCAlgorithmAES  // If this compiles, CommonCrypto is available
      ```
      
      **Implementation**:
      ```swift
      // Chrome uses: PBKDF2(password, salt="saltysalt", iterations=1003, keyLen=16)
      import CommonCrypto
      
      var derivedKey = [UInt8](repeating: 0, count: 16)
      CCKeyDerivationPBKDF(
          CCPBKDFAlgorithm(kCCPBKDF2),
          password, password.count,
          "saltysalt", 9,
          CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
          1003,
          &derivedKey, 16
      )
      ```
      
      **If CommonCrypto doesn't compile**:
      - Check Xcode version (requires 10.0+)
      - Try adding `import Darwin` before `import CommonCrypto`
      - As fallback, use `CryptoKit` (iOS 13+/macOS 10.15+) for PBKDF2

  4. **Read Cookies from SQLite**:
     ```swift
     // Copy DB to temp (Chrome locks it)
     // Query: SELECT name, encrypted_value, value FROM cookies WHERE host_key LIKE '%github.com%'
     ```

  5. **Decrypt Cookie Values**:
     ```swift
     // Cookie format: v10 or v11 prefix + AES-CBC encrypted data
     // IV: 16 spaces (0x20 * 16)
     // After decrypt: skip first 32 bytes (2 AES blocks of garbage)
     // Remove PKCS7 padding
     
     func decryptCookie(_ encrypted: Data) -> String? {
         guard encrypted.count > 3 else { return nil }
         let prefix = encrypted.prefix(3)
         guard prefix == Data("v10".utf8) || prefix == Data("v11".utf8) else {
             return String(data: encrypted, encoding: .utf8)  // Not encrypted
         }
         
         let ciphertext = encrypted.dropFirst(3)
         let iv = Data(repeating: 0x20, count: 16)  // 16 spaces
         
         // AES-CBC decrypt
         var decrypted = [UInt8](repeating: 0, count: ciphertext.count + kCCBlockSizeAES128)
         var decryptedLength = 0
         
         CCCrypt(CCOperation(kCCDecrypt),
                 CCAlgorithm(kCCAlgorithmAES),
                 CCOptions(0),  // No padding option, we handle it manually
                 derivedKey, 16,
                 [UInt8](iv),
                 [UInt8](ciphertext), ciphertext.count,
                 &decrypted, decrypted.count,
                 &decryptedLength)
         
         // Skip 32 byte prefix, remove PKCS7 padding
         let paddingLen = Int(decrypted[decryptedLength - 1])
         let valueStart = min(32, decryptedLength)
         let valueEnd = decryptedLength - paddingLen
         
         return String(bytes: decrypted[valueStart..<valueEnd], encoding: .utf8)
     }
     ```

  6. **Return Required Cookies**:
     ```swift
     struct GitHubCookies {
         let userSession: String?
         let ghSess: String?
         let dotcomUser: String?
         let loggedIn: String?
         
         var isValid: Bool { loggedIn == "yes" }
         var cookieHeader: String { /* build Cookie: header */ }
     }
     ```

  **References**:
  - `scripts/browser_cookies.py:69-168` - ChromiumCookieDecryptor class
  - `scripts/browser_cookies.py:270-323` - get_github_cookies_chromium function

  ---

  **7b. CopilotHistoryService (New File)**

  **What to do**:
  - Create `Services/CopilotHistoryService.swift`
  - Use BrowserCookieService to get GitHub cookies
  - Call `/settings/billing/copilot_usage_table` API
  - Parse daily history with model breakdown

  **API Details**:
  ```swift
  // Endpoint
  GET https://github.com/settings/billing/copilot_usage_table
      ?customer_id={id}&group=0&period=3&page={page}
  
  // Headers
  Cookie: {cookies from BrowserCookieService}
  Accept: application/json
  X-Requested-With: XMLHttpRequest
  User-Agent: Mozilla/5.0 ...
  ```

  **Response Structure**:
  ```json
  {
    "table": {
      "rows": [
        {
          "cells": [
            {"value": "Jan 29"},      // date
            {"value": "45"},          // included_requests
            {"value": "5"},           // billed_requests (overage)
            {"value": "$0.35"},       // gross_amount
            {"value": "$0.35"}        // billed_amount
          ],
          "subtable": {
            "rows": [
              {
                "cells": [
                  {"value": "gpt-4o"},
                  {"value": "30"},
                  {"value": "5"},
                  {"value": "$0.35"},
                  {"value": "$0.35"}
                ]
              }
            ]
          }
        }
      ]
    }
  }
  ```

  **Swift Parsing**:
  ```swift
  struct CopilotUsageHistory: Codable {
      struct TableRow {
          let date: String
          let includedRequests: Int
          let billedRequests: Int
          let grossAmount: String
          let billedAmount: String
          let models: [ModelUsage]
          
          struct ModelUsage {
              let name: String
              let included: Int
              let billed: Int
              let cost: String
          }
      }
      let rows: [TableRow]
  }
  
  func parseUsageTable(_ json: [String: Any]) -> [TableRow] {
      guard let table = json["table"] as? [String: Any],
            let rows = table["rows"] as? [[String: Any]] else { return [] }
      
      return rows.compactMap { row in
          guard let cells = row["cells"] as? [[String: Any]],
                cells.count >= 5 else { return nil }
          
          let date = cells[0]["value"] as? String ?? ""
          let included = Int(cells[1]["value"] as? String ?? "0") ?? 0
          let billed = Int(cells[2]["value"] as? String ?? "0") ?? 0
          let gross = cells[3]["value"] as? String ?? "$0"
          let billedAmt = cells[4]["value"] as? String ?? "$0"
          
          // Parse subtable for model breakdown
          var models: [ModelUsage] = []
          if let subtable = row["subtable"] as? [String: Any],
             let modelRows = subtable["rows"] as? [[String: Any]] {
              // ... parse model rows
          }
          
          return TableRow(date: date, includedRequests: included, ...)
      }
  }
  ```

  **References**:
  - `scripts/github_copilot_history.py:29-99` - GitHubCopilotAPI class
  - `scripts/github_copilot_history.py:101-140` - parse_daily_usage function

  ---

  **7c. Integration with CopilotProvider**

  **What to do**:
  - Add history fetching to existing `CopilotProvider`
  - Store history in `DetailedUsage.dailyHistory`
  - Handle fallback if cookie extraction fails

  ```swift
  func fetch() async throws -> ProviderResult {
      // Existing WebView-based fetch for current usage
      let currentUsage = try await fetchCurrentUsage()
      
      // New: Fetch history via cookies
      var dailyHistory: [DailyUsage]? = nil
      if let cookies = try? BrowserCookieService.shared.getGitHubCookies(),
         cookies.isValid {
          dailyHistory = try? await CopilotHistoryService.shared.fetchHistory(
              customerId: customerId,
              cookies: cookies
          )
      }
      
      return ProviderResult(
          usage: .quotaBased(remaining: remaining, entitlement: entitlement),
          details: DetailedUsage(dailyHistory: dailyHistory, ...)
      )
  }
  ```

  ---

  **Acceptance Criteria**:
  - BrowserCookieService successfully extracts cookies from at least one Chromium browser
  - Cookie decryption works correctly (AES-CBC with Keychain key)
  - History API returns last 7+ days
  - Each day shows: total requests, overage requests, cost
  - Model breakdown available per day
  - Graceful fallback if no valid cookies found

  **Commit**: YES (split into multiple commits)
  - Commit 1: `feat(service): add BrowserCookieService for Chromium cookie extraction`
    - Files: `Services/BrowserCookieService.swift`
  - Commit 2: `feat(service): add CopilotHistoryService for daily usage API`
    - Files: `Services/CopilotHistoryService.swift`
  - Commit 3: `feat(copilot): integrate history service with CopilotProvider`
    - Files: `Providers/CopilotProvider.swift`

---

- [ ] 8. Split Copilot Display into Add-on + Quota (UI-ONLY, No New Provider)

  **What to do**:
  - Display `currentUsage: CopilotUsage` TWICE in menu (same data, different views):
    1. **Pay-as-you-go section**: "Copilot Add-on $X.XX" using `netBilledAmount`
    2. **Quota section**: "Copilot XX%" using `remaining/entitlement`
  - NO new provider class needed - this is purely UI rendering

  **Data Split**:
  | Field | Copilot Add-on | Copilot Quota |
  |-------|----------------|---------------|
  | netBilledAmount | ✓ (main display) | - |
  | billedRequests | ✓ (overage count) | - |
  | discountQuantity | - | ✓ (used) |
  | entitlement | - | ✓ (limit) |
  | dailyHistory | billedRequests only | all requests |

  **References**:
  - `CopilotMonitor/CopilotMonitor/Models/CopilotUsage.swift`
  - `CopilotMonitor/CopilotMonitor/Providers/CopilotProvider.swift`

  **EXPLICIT DECISION: CopilotAddon is UI-ONLY (No New Provider)**

  **Rule**: `.copilotAddon` identifier is NOT needed. Copilot data is displayed TWICE using SAME data source.

  **Rationale**:
  - `CopilotUsage` struct already contains ALL needed data:
    - `netBilledAmount` → Pay-as-you-go $ display
    - `usedRequests` / `limitRequests` → Quota % display
  - Creating `CopilotAddonProvider` would duplicate API calls
  - Simpler: Display same `currentUsage: CopilotUsage` in two sections

  **Implementation in `updateMultiProviderMenu()` (line ~981+)**:

  Current code already does this partially:
  ```swift
  // Line 994-1006: Pay-as-you-go section (Copilot Add-on)
  if let copilotUsage = currentUsage, copilotUsage.netBilledAmount > 0 {
      let addOnItem = NSMenuItem(
          title: String(format: "Copilot Add-on    $%.2f", copilotUsage.netBilledAmount),
          action: nil, keyEquivalent: ""
      )
      // ...
  }
  
  // Line 1044-1055: Quota section (Copilot)
  if let copilotUsage = currentUsage {
      let percentage = ...
      let quotaItem = createQuotaMenuItem(identifier: .copilot, percentage: percentage)
      // ...
  }
  ```

  **Change Needed**:
  - Remove the `copilotUsage.netBilledAmount > 0` condition for Pay-as-you-go section
  - ALWAYS show "Copilot Add-on $0.00" (even when no overage)
  - This makes menu structure consistent regardless of whether user has overages
  
  ```swift
  // CHANGE: Remove the > 0 condition
  if let copilotUsage = currentUsage {
      let addOnItem = NSMenuItem(
          title: String(format: "Copilot Add-on    $%.2f", copilotUsage.netBilledAmount),
          action: nil, keyEquivalent: ""
      )
      // ...
  }
  ```

  **Task 1 Update**: Do NOT add `.copilotAddon` to ProviderIdentifier enum.
  
  **Final Provider List**:
  - `.copilot` - existing (Quota display)
  - `.claude` - existing (Quota)
  - `.codex` - existing (Quota)
  - `.geminiCLI` - existing (Quota)
  - `.openRouter` - existing (Pay-as-you-go $)
  - `.openCode` - existing (keep as-is, see note below)
  - `.antigravity` - NEW (Quota)
  - `.openCodeZen` - NEW (Pay-as-you-go $)

  **EXPLICIT DECISION on OpenCodeProvider vs OpenCodeZenProvider**:
  
  | Provider | Purpose | Action |
  |----------|---------|--------|
  | `OpenCodeProvider` (existing) | API token-based access | **KEEP** in code, **HIDE** in menu |
  | `OpenCodeZenProvider` (new) | CLI-based cost tracking | **ADD** to ProviderManager |
  | `.openCode` identifier | Existing enum case | **KEEP** (don't delete to avoid breaking changes) |
  | `.openCodeZen` identifier | New enum case | **ADD** (Task 1) |
  
  **Rationale**: 
  - Deleting `.openCode` would break UserDefaults keys like `provider.open_code.enabled`
  - Safer to keep identifier but hide from menu display
  
  **Final Provider Registration** (`ProviderManager.swift:registerDefaultProviders()`):
  ```swift
  providers = [
      ClaudeProvider(),       // Quota
      CodexProvider(),        // Quota
      GeminiCLIProvider(),    // Quota
      OpenRouterProvider(),   // Pay-as-you-go ($)
      // OpenCodeProvider(),  // ← COMMENT OUT (keep code, don't register)
      AntigravityProvider(),  // Quota (NEW)
      OpenCodeZenProvider()   // Pay-as-you-go ($) (NEW)
  ]
  ```
  
  **Enabled Providers Menu Handling** (`StatusBarController.swift:562-568`):
  
  Current code iterates `ProviderIdentifier.allCases`. To hide `.openCode`:
  ```swift
  // Option A: Filter out .openCode from menu
  for identifier in ProviderIdentifier.allCases where identifier != .openCode {
      // ...
  }
  
  // Option B: Add `isVisibleInMenu` property to ProviderIdentifier
  var isVisibleInMenu: Bool {
      switch self {
      case .openCode: return false  // Hide deprecated provider
      default: return true
      }
  }
  ```
  
  **UserDefaults Migration**: None needed - keeping `.openCode` preserves backward compatibility

  **Acceptance Criteria**:
  ```bash
  # 1. Build succeeds
  xcodebuild -project CopilotMonitor/CopilotMonitor.xcodeproj -scheme CopilotMonitor -configuration Debug build 2>&1 | grep "BUILD SUCCEEDED"
  
  # 2. Menu displays Copilot in BOTH sections:
  # Pay-as-you-go section: "🐙 Copilot Add-on    $0.00 ▸"
  # Quota section: "🐙 Copilot    65% ▸"
  
  # 3. Submenus have different content:
  # Add-on submenu: Overage requests, daily history with billedRequests
  # Quota submenu: Progress bar, used count, free quota
  ```

  **Commit**: YES
  - Message: `feat(ui): display Copilot in both Pay-as-you-go and Quota sections`
  - Files: `StatusBarController.swift` (UI changes only, no new provider file)

---

- [ ] 9. Update OpenRouterProvider Display

  **What to do**:
  - Change main display from utilization% to `usage_monthly` ($)
  - Submenu: Credits remaining ($X/$Y Z%)
  - Return pay-as-you-go usage with dollar amount

  **References**:
  - `CopilotMonitor/CopilotMonitor/Providers/OpenRouterProvider.swift`

  **Current vs New Display**:
  | Before | After |
  |--------|-------|
  | "OpenRouter 45%" (utilization) | "OpenRouter $37.42" (monthly cost) |

  **DetailedUsage Fields to Populate**:
  - `monthlyCost: Double` - usage_monthly from API
  - `creditsRemaining: Double` - remaining credits
  - `creditsTotal: Double` - total credits
  - `dailyCost: Double?` - usage_daily from API
  - `weeklyCost: Double?` - usage_weekly from API

  **Acceptance Criteria**:
  ```bash
  # 1. Build succeeds
  xcodebuild -project CopilotMonitor/CopilotMonitor.xcodeproj -scheme CopilotMonitor -configuration Debug build 2>&1 | grep "BUILD SUCCEEDED"
  
  # 2. Menu shows dollar amount, not percentage:
  # Expected: "🌐 OpenRouter    $37.42 ▸"
  # NOT: "🌐 OpenRouter    45% ▸"
  
  # 3. Submenu shows credit details:
  # "Credits: $131/$6,685 (2%)"
  # "Daily: $0.00"
  # "Weekly: $0.00"
  ```

  **Commit**: YES
  - Message: `feat(openrouter): change to monthly cost display with credit details`
  - Files: `OpenRouterProvider.swift`

---

- [ ] 10. Menu Restructure (Pay-as-you-go / Quota Sections)

  **What to do**:
  - Restructure `updateMultiProviderMenu()`:
    1. **Header**: "Pay-as-you-go" with total sum ($322.81)
    2. **Pay-as-you-go items**: OpenRouter, OpenCode Zen, Copilot Add-on
       - Each shows: `Provider Name    $XX.XX ▸`
    3. **Separator**
    4. **Header**: "Quota Status"
    5. **Quota items**: Claude, Codex, Gemini CLI, Antigravity, Copilot
       - Each shows: `Provider Name    XX% ▸`
  - Calculate pay-as-you-go total sum
  - Update menu bar icon to show total cost

  ---

  **Current Implementation** (already partially done):
  
  File: `CopilotMonitor/CopilotMonitor/App/StatusBarController.swift:981-1070`
  
  The menu already has Pay-as-you-go and Quota Status sections:
  ```swift
  // Line 986-990: Pay-as-you-go header (no total yet)
  let payAsYouGoHeader = NSMenuItem(title: "Pay-as-you-go", action: nil, keyEquivalent: "")
  
  // Line 994-1006: Copilot Add-on (only if overage > 0)
  if let copilotUsage = currentUsage, copilotUsage.netBilledAmount > 0 { ... }
  
  // Line 1008-1021: Other pay-as-you-go providers (using utilization%, not $)
  if case .payAsYouGo(let utilization, _) = result.usage { ... }
  
  // Line 1036-1040: Quota Status header
  let quotaHeader = NSMenuItem(title: "Quota Status", action: nil, keyEquivalent: "")
  ```

  ---

  **Changes Needed**:

  **1. Calculate Pay-as-you-go Total**:
  ```swift
  func calculatePayAsYouGoTotal(providerResults: [ProviderIdentifier: ProviderResult], copilotUsage: CopilotUsage?) -> Double {
      var total = 0.0
      
      // Copilot Add-on overage
      if let copilot = copilotUsage {
          total += copilot.netBilledAmount
      }
      
      // Other pay-as-you-go providers
      for (_, result) in providerResults {
          if case .payAsYouGo(_, let cost, _) = result.usage, let cost = cost {
              total += cost
          }
      }
      
      return total
  }
  ```

  **2. Update Pay-as-you-go Header**:
  ```swift
  let total = calculatePayAsYouGoTotal(providerResults: providerResults, copilotUsage: currentUsage)
  let payAsYouGoHeader = NSMenuItem(
      title: String(format: "Pay-as-you-go                    $%.2f", total),
      action: nil, keyEquivalent: ""
  )
  ```

  **3. Display $ Instead of % for Pay-as-you-go Items**:
  ```swift
  // BEFORE (current):
  let item = createPayAsYouGoMenuItem(identifier: identifier, utilization: utilization)
  
  // AFTER (new):
  if case .payAsYouGo(_, let cost, _) = result.usage {
      let costValue = cost ?? 0.0
      let item = NSMenuItem(
          title: String(format: "%@    $%.2f", identifier.displayName, costValue),
          action: nil, keyEquivalent: ""
      )
  }
  ```

  **4. Update Status Bar Icon to Show Total Cost**:
  
  File: `CopilotMonitor/CopilotMonitor/App/StatusBarController.swift:59-175`
  
  **Current Implementation** (`StatusBarIconView`):
  - Custom `NSView` subclass with manual drawing
  - Shows: Copilot icon + circular progress + used count
  - OR: Copilot icon + add-on cost (when `addOnCost > 0`)
  - Key method: `update(used: Int, limit: Int, cost: Double = 0)`
  
  **Current Logic** (line 88-96):
  ```swift
  func update(used: Int, limit: Int, cost: Double = 0) {
      usedCount = used
      addOnCost = cost
      percentage = limit > 0 ? min((Double(used) / Double(limit)) * 100, 100) : 0
      // ...
  }
  ```
  
  When `addOnCost > 0`, the view shows cost text (line 121-122):
  ```swift
  if addOnCost > 0 {
      drawCostText(at: NSPoint(x: 22, y: 3), isDark: isDark)
  }
  ```

  **Changes Needed**:
  
  **Option A (RECOMMENDED)**: Extend existing `update()` to accept total pay-as-you-go cost
  ```swift
  // Rename parameter for clarity
  func update(used: Int, limit: Int, totalPayAsYouGoCost: Double = 0) {
      usedCount = used
      addOnCost = totalPayAsYouGoCost  // This drives the $ display
      // ...
  }
  ```
  
  Then in `updateUIForSuccess()` or wherever icon is updated:
  ```swift
  let total = calculatePayAsYouGoTotal(providerResults: providerResults, copilotUsage: currentUsage)
  statusBarIconView.update(used: usage.usedRequests, limit: usage.limitRequests, totalPayAsYouGoCost: total)
  ```
  
  **Result**: Status bar shows total pay-as-you-go cost instead of just Copilot add-on cost

  ---

  **Provider Classification & EXPLICIT ORDERING**:
  
  **CRITICAL**: Dictionary iteration is non-deterministic. Use HARDCODED order:
  
  ```swift
  // HARDCODED ORDER for stable menu display
  let payAsYouGoOrder: [ProviderIdentifier] = [.openRouter, .openCodeZen]
  let quotaOrder: [ProviderIdentifier] = [.claude, .codex, .geminiCLI, .antigravity, .copilot]
  
  // Pay-as-you-go section (iterate in order, not from dictionary)
  for identifier in payAsYouGoOrder {
      if let result = providerResults[identifier] {
          // Add menu item
      }
  }
  // Add Copilot Add-on separately (from currentUsage, not providerResults)
  
  // Quota section (iterate in order)
  for identifier in quotaOrder {
      if identifier == .copilot {
          // Handle from currentUsage
      } else if let result = providerResults[identifier] {
          // Add menu item
      }
  }
  ```
  
  | Order | Provider | Section | Display Format | Data Source |
  |-------|----------|---------|----------------|-------------|
  | 1 | OpenRouter | Pay-as-you-go | $XX.XX | `ProviderUsage.payAsYouGo.cost` |
  | 2 | OpenCode Zen | Pay-as-you-go | $XX.XX | `ProviderUsage.payAsYouGo.cost` |
  | 3 | Copilot Add-on | Pay-as-you-go | $XX.XX | `CopilotUsage.netBilledAmount` |
  | 4 | Claude | Quota | XX% | `ProviderUsage.quotaBased` |
  | 5 | Codex | Quota | XX% | `ProviderUsage.quotaBased` |
  | 6 | Gemini CLI | Quota | XX% | `ProviderUsage.quotaBased` |
  | 7 | Antigravity | Quota | XX% | `ProviderUsage.quotaBased` |
  | 8 | Copilot | Quota | XX% | `CopilotUsage.remaining/entitlement` |
  
  **Menu Item Enabled State** (fix grayed-out issue):
  - Items with submenus: Set `isEnabled = true` even if `action = nil`
  - Items without submenus: Can remain disabled for headers
  
  ```swift
  let item = NSMenuItem(title: "OpenRouter    $37.42", action: nil, keyEquivalent: "")
  item.isEnabled = true  // ← CRITICAL: Enable so it's not grayed out
  item.submenu = createDetailSubmenu(...)  // Having submenu makes it interactive
  ```

  ---

  **Acceptance Criteria**:
  ```bash
  # 1. Build succeeds
  xcodebuild -project CopilotMonitor/CopilotMonitor.xcodeproj -scheme CopilotMonitor -configuration Debug build 2>&1 | grep "BUILD SUCCEEDED"
  
  # 2. Run app and verify menu structure:
  # - "Pay-as-you-go                    $XXX.XX" header with total
  # - Pay-as-you-go items show "$XX.XX" not "XX%"
  # - "Quota Status" header
  # - Quota items show "XX%"
  
  # 3. Status bar icon shows total pay-as-you-go cost
  # Expected: "$322.81" in menu bar (if costs exist)
  # Or: Just icon (if $0.00)
  ```

  **Commit**: YES
  - Message: `feat(ui): add pay-as-you-go total and $ display for cost providers`
  - Files: `StatusBarController.swift`

---

- [x] 11. Detail Submenus for All Providers

  **What to do**:
  - Create/update `createDetailSubmenu()` for each provider type:
    - **OpenRouter**: Credits, Daily, Weekly
    - **OpenCode Zen**: Avg/Day, Sessions, Messages, Top Models, History
    - **Copilot Add-on**: Overage Requests, History
    - **Claude**: 5h, 7d, Sonnet, Opus, Extra Usage
    - **Codex**: Primary, Secondary, Plan, Credits
    - **Gemini CLI**: Per-model quotas
    - **Antigravity**: Per-model quotas, Plan, Email
    - **Copilot**: Progress bar, Used, Free Quota

  **References**:
  - `CopilotMonitor/CopilotMonitor/App/StatusBarController.swift`
  - Current method: `createDetailSubmenu()` or similar

  **Expected Submenu Content**:

  **OpenRouter** (`$37.42 ▸`):
  ```
  Credits: $131/$6,685 (2%)
  Daily: $0.00
  Weekly: $0.00
  ```

  **OpenCode Zen** (`$285.39 ▸`):
  ```
  Avg/Day: $9.51
  Sessions: 4,845
  Messages: 104,008
  ─────────────
  Top Models:
     gpt-5.2: $55.55
     gemini-3-flash: $25.99
     gpt-5.2-codex: $1.30
  ─────────────
  Usage History ▸
     Jan 30: $0.00
     Jan 29: $0.00
     ...
  ```

  **Claude** (`78% ▸`):
  ```
  5h Window: 78%
     Resets: 17:00
  7d Window: 82%
     Resets: Feb 5
  ─────────────
  Sonnet (7d): 90%
  Opus (7d): 100%
  Extra Usage: OFF
  ```

  **Codex** (`92% ▸`):
  ```
  Primary: 92% (5h)
  Secondary: 92% (53h)
  ─────────────
  Plan: Pro
  Credits: $0.00
  ```

  **Gemini CLI** (`100% ▸`):
  ```
  gemini-2.0-flash: 100%
  gemini-2.5-flash: 100%
  gemini-2.5-pro: 100%
  ```

  **Antigravity** (`80% ▸`):
  ```
  Gemini 3 Pro (High): 100%
  Gemini 3 Pro (Low): 100%
  Gemini 3 Flash: 100%
  Claude Sonnet 4.5: 80%
  Claude Opus 4.5: 80%
  ─────────────
  Plan: Free
  Email: kars@kargn.as
  ```

  **Copilot Quota** (`65% ▸`):
  ```
  [═══════░░░] 350/1000
  This Month: 650 used
  Free Quota: 1000
  ```

  **Copilot Add-on** (`$0.00 ▸`):
  ```
  Overage Requests: 0
  Usage History ▸
     Jan 30: 0 overage ($0.00)
     Jan 29: 0 overage ($0.00)
     ...
  ```

  **Acceptance Criteria**:
  ```bash
  # 1. Build succeeds
  xcodebuild -project CopilotMonitor/CopilotMonitor.xcodeproj -scheme CopilotMonitor -configuration Debug build 2>&1 | grep "BUILD SUCCEEDED"
  
  # 2. Run app and click on each provider's arrow (▸)
  # Verify submenu appears with correct content structure
  
  # 3. All submenus should:
  # - Display data from DetailedUsage fields
  # - Use consistent formatting (separators, indentation)
  # - NOT show "N/A" or empty values (hide unavailable fields)
  ```

  **Commit**: YES
  - Message: `feat(ui): add detail submenus for all providers`
  - Files: `StatusBarController.swift`

---

- [ ] 12. Icon Resizing + Cleanup

  **What to do**:
  - Resize all provider icons to 16x16 via runtime resizing (icons are PDF vectors)
  - Remove Sign In/Reset Login menu items
  - Clean up unused code

  ---

  **12a. Icon Resizing**

  **Asset Catalog Location**: `CopilotMonitor/CopilotMonitor/Assets.xcassets/`
  
  **Provider Icons** (all PDF vector format):
  - `AntigravityIcon.imageset/antigravity-icon.pdf`
  - `ClaudeIcon.imageset/claude-icon.pdf`
  - `CodexIcon.imageset/codex-icon.pdf`
  - `CopilotIcon.imageset/copilot-icon.pdf`
  - `GeminiIcon.imageset/gemini-icon.pdf`
  - `OpencodeIcon.imageset/opencode-icon.pdf`
  - `ZaiIcon.imageset/zai-icon.pdf`

  **Approach**: Runtime resizing (PDFs scale well)
  
  Find `iconForProvider()` or similar in `StatusBarController.swift` and ensure:
  ```swift
  func iconForProvider(_ identifier: ProviderIdentifier) -> NSImage? {
      let iconName = identifier.iconName  // e.g., "CopilotIcon"
      guard let image = NSImage(named: iconName) else { return nil }
      
      // Resize to 16x16 for menu items
      image.size = NSSize(width: 16, height: 16)
      return image
  }
  ```

  **Verification**: Run app, hover over menu items, icons should appear small (16x16)

  ---

  **12b. Sign In/Reset Login Removal**

  **Current Implementation** (`StatusBarController.swift`):
  ```swift
  // Line 509-517: Menu item creation
  signInItem = NSMenuItem(title: "Sign In", action: #selector(signInClicked), keyEquivalent: "")
  signInItem.image = NSImage(systemSymbolName: "person.crop.circle.badge.checkmark", ...)
  signInItem.target = self
  menu.addItem(signInItem)

  resetLoginItem = NSMenuItem(title: "Reset Login", action: #selector(resetLoginClicked), keyEquivalent: "")
  resetLoginItem.image = NSImage(systemSymbolName: "arrow.counterclockwise", ...)
  resetLoginItem.target = self
  menu.addItem(resetLoginItem)
  
  // Line 1202-1204: signInClicked handler
  @objc private func signInClicked() {
      NotificationCenter.default.post(name: Notification.Name("sessionExpired"), object: nil)
  }
  
  // Line 1211-1224: resetLoginClicked handler
  @objc private func resetLoginClicked() {
      Task { @MainActor in
          await AuthManager.shared.resetSession()
          clearCaches()
          currentUsage = nil
          customerId = nil
          usageHistory = nil
          lastHistoryFetchResult = .none
          historyFetchTimer?.invalidate()
          historyFetchTimer = nil
          updateUIForLoggedOut()
          NotificationCenter.default.post(name: Notification.Name("sessionExpired"), object: nil)
      }
  }
  ```

  **IMPORTANT DECISION**: Keep or Remove WebView-based Auth?

  **Option A (RECOMMENDED)**: Keep WebView auth, HIDE menu items (not delete)
  - Current CopilotProvider still requires WebView for usage data
  - BrowserCookieService (Task 7) is ONLY for History API, not main usage
  - HIDE menu items instead of removing (avoids nil reference issues)
  
  **Option B**: Full migration to cookie-only (complex, scope creep)
  - Requires rewriting CopilotProvider to use URLSession + cookies
  - Much larger scope change

  **Recommendation**: Go with Option A (HIDE, not REMOVE)

  **CRITICAL: IUO Nil Safety**
  
  `signInItem` and `resetLoginItem` are declared as implicitly unwrapped optionals (IUO):
  ```swift
  // Line 401-402
  private var signInItem: NSMenuItem!
  private var resetLoginItem: NSMenuItem!
  ```
  
  These are referenced in multiple places:
  - Line 969: `if item == signInItem { break }` (menu rebuild loop)
  - Line 1187: `signInItem.isHidden = true` (updateUIForSuccess)
  - Line 1194: `signInItem.isHidden = false` (updateUIForLoggedOut)

  **SAFE APPROACH**:
  1. KEEP creating the menu items in `setupMenu()`
  2. Set them as hidden immediately after creation:
     ```swift
     signInItem = NSMenuItem(title: "Sign In", action: #selector(signInClicked), keyEquivalent: "")
     // ... setup ...
     menu.addItem(signInItem)
     signInItem.isHidden = true  // ← ADD THIS
     
     resetLoginItem = NSMenuItem(title: "Reset Login", action: #selector(resetLoginClicked), keyEquivalent: "")
     // ... setup ...
     menu.addItem(resetLoginItem)
     resetLoginItem.isHidden = true  // ← ADD THIS
     ```
  3. Remove visibility toggles in `updateUIForSuccess()` and `updateUIForLoggedOut()`:
     ```swift
     // REMOVE: signInItem.isHidden = true/false
     // REMOVE: resetLoginItem.isHidden = true/false
     ```
  4. KEEP handler methods (`signInClicked()`, `resetLoginClicked()`) - they may be triggered by notifications

  **Why This Is Safe**:
  - Menu items still exist → no nil crash
  - `.isHidden = true` → not visible to user
  - Auth still works via notification-triggered flow
  - Existing code referencing these items still compiles and runs

  ---

  **Acceptance Criteria**:
  ```bash
  # 1. Build succeeds
  xcodebuild -project CopilotMonitor/CopilotMonitor.xcodeproj -scheme CopilotMonitor -configuration Debug build 2>&1 | grep "BUILD SUCCEEDED"
  
  # 2. Run app and verify:
  # - NO "Sign In" menu item visible
  # - NO "Reset Login" menu item visible
  # - Provider icons are 16x16 (visually smaller, not oversized)
  
  # 3. Copilot still works (auth happens via WebView in background)
  ```

  **Commit**: YES
  - Message: `fix(ui): resize icons to 16x16 and remove Sign In/Reset menu items`
  - Files: `StatusBarController.swift`

---

## Commit Strategy

| Task | Message | Files |
|------|---------|-------|
| 1 | `feat(model): add provider identifiers and extend DetailedUsage` | ProviderResult.swift, ProviderProtocol.swift |
| 2 | `feat(provider): add AntigravityProvider` | AntigravityProvider.swift |
| 3 | `feat(provider): add OpenCodeZenProvider with history` | OpenCodeZenProvider.swift |
| 4 | `feat(claude): add 5h/7d/Sonnet/Opus` | ClaudeProvider.swift |
| 5 | `feat(codex): add plan/secondary/credits` | CodexProvider.swift |
| 6 | `feat(gemini): add per-model quota` | GeminiCLIProvider.swift |
| 7 | `feat(copilot): implement native history API` | CopilotProvider.swift |
| 8 | `feat(ui): display Copilot in Pay-as-you-go and Quota sections` | StatusBarController.swift |
| 9 | `feat(openrouter): monthly cost display` | OpenRouterProvider.swift |
| 10 | `feat(ui): Pay-as-you-go/Quota menu sections` | StatusBarController.swift |
| 11 | `feat(ui): detail submenus for all providers` | StatusBarController.swift |
| 12 | `fix(ui): icons 16x16 + remove Sign In/Reset` | StatusBarController.swift |

---

## Success Criteria

### Final Checklist
- [ ] Menu bar shows total pay-as-you-go cost
- [ ] Pay-as-you-go section: OpenRouter ($), OpenCode Zen ($), Copilot Add-on ($)
- [ ] Quota section: Claude (%), Codex (%), Gemini CLI (%), Antigravity (%), Copilot (%)
- [ ] OpenRouter submenu: Credits, Daily, Weekly
- [ ] OpenCode Zen submenu: Stats + Daily History
- [ ] Copilot Add-on submenu: Overage + History
- [ ] Claude submenu: 5h, 7d, Sonnet, Opus, Extra Usage
- [ ] Codex submenu: Primary, Secondary, Plan, Credits
- [ ] Gemini CLI submenu: Per-model quotas
- [ ] Antigravity submenu: Per-model quotas, Plan, Email
- [ ] Copilot submenu: Progress bar, Used, Free Quota
- [ ] All icons 16x16
- [ ] Sign In/Reset Login removed
- [ ] Build succeeds
