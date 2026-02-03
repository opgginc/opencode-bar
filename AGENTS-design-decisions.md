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

</design_decisions>
