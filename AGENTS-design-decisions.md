# Design Decisions

> **WARNING**: The following design decisions are intentional. Do NOT modify without explicit user approval.

<design_decisions>

## Menu Structure
```
[🔍 $256.61]
```

```
─────────────────────────────
Pay-as-you-go: $37.61
  OpenRouter       $37.42    ▸
  OpenCode Zen     $0.19     ▸
─────────────────────────────
Quota Status: $219/m
  Copilot (0%)           ▸
  Claude (60%)           ▸
  Codex (100%)           ▸
  Gemini CLI #1 (100%)   ▸
─────────────────────────────
Predicted EOM: $451
─────────────────────────────
Refresh (⌘R)
Auto Refresh Period       ▸
Settings                  ▸
─────────────────────────────
OpenCode Bar v2.1.0
View Error Details...
Check for Updates...
Quit (⌘Q)
```

## Labeling Details

### Title in macOS MenuBar
- Displays the sum of all Pay-as-you-go and Subscription costs
  - Format: `$256.61`
- If the total is zero, show the app's short title instead of `$XXX.XX`
  - Format: `OC Bar`

### Provider Categories

#### Pay-as-you-go
- **Providers**
  - **OpenRouter** - Credits-based billing
  - **OpenCode Zen** - Usage-based billing
  - **GitHub Copilot Add-on** - Usage-based billing
- **Features**
  - Subscription Cost Setting: ❌ NO subscription settings
- **Warnings**
  - **NEVER** add subscription settings to Pay-as-you-go providers (OpenRouter, OpenCode Zen)

#### Quota-based
- **Providers**
  - **Claude** - Time-window based quotas (5h/7d)
  - **Codex** - Time-window based quotas
  - **Kimi** - Time-window based quotas
  - **GitHub Copilot** - Credits-based quotas with overage billing (Overage billing will be charged as `Add-on` in Pay-as-you-go)
  - **Gemini CLI** - Per-model quota limits
  - **Antigravity** - Local server monitoring by Antigravity IDE
  - **Z.AI Coding Plan** - Time-window based & tool usage based quotas
  - **Chutes AI** - Time-window based quotas, credits balance
- **Features**
  - ✅ Subscription settings available. You can set custom costs for each provider and account.
  - All of the providers here should have Subscription settings.
- **Warnings**
  - **NEVER** remove subscription settings from Quota-based providers

### Menu Group Titles (IMMUTABLE)

#### Pay-as-you-go
- Header Format: `Pay-as-you-go: $XX.XX`
- Example: `Pay-as-you-go: $37.61`

#### Quota Status
- Header Format: `Quota Status: $XXX/m` (if subscriptions exist)
- Header Format: `Quota Status` (if no subscriptions)
- Example: `Quota Status: $288/m` or `Quota Status`

### Formatting time
- Absolute time:
  - Standard time format: `2026-01-31 14:23 PST`
  - All times are displayed in the user's local timezone
- Relative time:
  - Standard relative format: `in 5h 23m` or `3h 12m ago`

### Rules
- **NEVER** change the menu group title formats without explicit approval
- Pay-as-you-go header displays the sum of all pay-as-you-go costs (excluding subscription costs)
- Quota Status header displays the monthly subscription total with `/m` suffix

### Quota Display Rules (from PR #54, #55)
- **Prefer to use 'used' instead of 'left'**: Prefer to use percentage is "used" instead of "left/remaining"
  - ✅ `3h: 75% used`
  - ❌ `23%` (ambiguous - is it used or remaining?)
  - ❌ `23% remaining`
- **Specify time**: Always include time component when displaying quota with time limits
  - ✅ `5h: 60% used`
  - ❌ `Primary: 75%` (ambiguous - what's Primary?)
- **Wait Time Formatting**: When quota is exhausted, show wait time with consistent granularity
  - `>=1d`: Show `Xd Yh` format (e.g., `1d 5h`)
  - `>=1h`: Show `Xh` format (e.g., `3h`)
  - `<1h`: Show `Xm` format (e.g., `45m`)
- **Auth Source Labels**: Every provider MUST display where the auth token was detected
  - Format: `Token From: <path>` in submenu
  - Examples: `~/.local/share/opencode/auth.json`, `VS Code`, `Keychain`

### Multi-Account Provider Rules (from PR #55)
- **CandidateDedupe**: Use shared `CandidateDedupe.merge()` for deduplicating multi-account providers
- **isReadableFile Check**: Always verify file readability before accessing auth files
  - Pattern: `FileManager.fileExists(atPath:)` AND `FileManager.isReadableFile(atPath:)`

</design_decisions>
