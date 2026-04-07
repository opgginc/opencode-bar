<p align="center">
  <img src="docs/screenshot-subscription.png" alt="OpenCode Bar Screenshot" width="40%">
  <img src="docs/screenshot3.png" alt="OpenCode Bar Screenshot" width="40%">
</p>

<p align="center">
  <strong>Automatically monitor all your AI provider usage from OpenCode in real-time from the macOS menu bar.</strong>
</p>

<p align="center">
  <a href="https://github.com/opgginc/opencode-bar/releases/latest">
    <img src="https://img.shields.io/github/v/release/opgginc/opencode-bar?style=flat-square" alt="Release">
  </a>
  <a href="https://github.com/opgginc/opencode-bar/blob/main/LICENSE">
    <img src="https://img.shields.io/github/license/opgginc/opencode-bar?style=flat-square" alt="License">
  </a>
  <img src="https://img.shields.io/badge/platform-macOS%2013%2B-blue?style=flat-square" alt="Platform">
  <img src="https://img.shields.io/badge/swift-5.9-orange?style=flat-square" alt="Swift">
</p>

---

## Installation

### Homebrew (Easy)

```bash
brew install --cask opgginc/tap/opencode-bar
```

### Download

Download the latest `.dmg` file from the [**Releases**](https://github.com/opgginc/opencode-bar/releases/latest) page.

## Overview

**OpenCode Bar** automatically detects and monitors all AI providers registered in your [OpenCode](https://opencode.ai) configuration. No manual setup required - just install and see your usage across all providers in one unified dashboard.

### Supported Providers (Auto-detected from OpenCode)

| Provider | Type | Key Metrics |
|----------|------|-------------|
| **OpenRouter** | Pay-as-you-go | Credits balance, daily/weekly/monthly cost |
| **OpenCode Zen** | Pay-as-you-go | Daily history (30 days), model breakdown |
| **GitHub Copilot Add-on** | Pay-as-you-go | Usage-based billing after exceeding quota |
| **Claude** | Quota-based | 5h/7d usage windows, Sonnet/Opus breakdown |
| **Codex** | Quota-based | Primary/Secondary quotas, plan type |
| **Gemini CLI** | Quota-based | Per-model quotas, multi-account support with email labels and account ID details |
| **Nano-GPT** | Quota-based | Weekly input tokens quota, USD/NANO balance |
| **Kimi for Coding (Kimi K2.5)** | Quota-based | Usage limits, membership level, reset time |
| **MiniMax Coding Plan** | Quota-based | 5h/weekly quotas, Anthropic-style dual-window submenu, OpenCode auth |
| **Z.AI Coding Plan** | Quota-based | Token/MCP quotas, model usage, tool usage (24h) |
| **Brave Search** | Quota-based | Monthly search quota, reset schedule |
| **Tavily** | Quota-based | Monthly search quota, plan usage |
| **Synthetic** | Quota-based | 5h usage limit, request limits, reset time |
| **Antigravity** | Quota-based | Local cache reverse parsing (`state.vscdb`), no localhost dependency |
| **Chutes AI** | Quota-based | Daily quota limits (300/2000/5000), credits balance |
| **GitHub Copilot** | Quota-based | Multi-account, daily history, overage tracking, auth source labels |

### OpenCode Plugins
- **ChatGPT / Codex**
  - `ndycode/oc-chatgpt-multi-auth`
  - Reads `~/.opencode/openai-codex-accounts.json` and `~/.opencode/projects/*/openai-codex-accounts.json`
  - Also understands plugin-managed OpenCode `auth.json` fields such as `idToken`, `accountIdOverride`, and `organizationIdOverride`
- **Antigravity/Gemini**
  - `NoeFabris/opencode-antigravity-auth` (writes `~/.config/opencode/antigravity-accounts.json`)
  - `jenslys/opencode-gemini-auth` (writes `google.oauth` in OpenCode `auth.json`)
  - Gemini CLI OAuth creds (writes `~/.gemini/oauth_creds.json` for email/account ID metadata; overlaps are merged with Antigravity accounts)
- **Claude**: `anomalyco/opencode-anthropic-auth`

### Standalone tools
- **Codex**: `Soju06/codex-lb` (writes `~/.codex-lb/`)

### Other AI agents beyond OpenCode that supports auto-detection
- **GitHub Copilot** (multi-source discovery)
  - **OpenCode auth** - Auto-detected from OpenCode `auth.json` (`copilot` provider entry)
  - **Copilot CLI** - Auto-detected through macOS Keychain (`github.com` entries)
  - **VS Code / Cursor** - Auto-detected from `~/.config/github-copilot/hosts.json` and `~/.config/github-copilot/apps.json`
  - **Browser Cookies** - Chrome, Brave, Arc, Edge session cookies
  - Multiple accounts from different sources are automatically deduplicated and merged
- **Codex**
  - **OpenCode + oc-chatgpt-multi-auth** - Auto-detected from OpenCode `auth.json` plus `~/.opencode/.../openai-codex-accounts.json`
  - **Codex for Mac** - Auto-detected through `~/.codex/auth.json`
  - **Codex CLI** - Auto-detected through `~/.codex/auth.json`
  - **codex-lb** - Auto-detected through `~/.codex-lb/`
- **Claude Code CLI** - Keychain-based authentication detection

## Features

### Automatic Provider Detection
- **Zero Configuration**: Reads your OpenCode `auth.json` automatically
- **Multi-path Support**: Searches `$XDG_DATA_HOME/opencode`, `~/.local/share/opencode`, and `~/Library/Application Support/opencode`
- **Dynamic Updates**: New providers appear as you add them to OpenCode
- **Smart Categorization**: Pay-as-you-go vs Quota-based providers displayed separately

### Real-time Monitoring
- **Menu Bar Dashboard**: View all provider usage at a glance
- **Visual Indicators**: Color-coded progress (green → yellow → orange → red)
- **Detailed Submenus**: Click any provider for in-depth metrics
- **Auth Source Labels**: See where each account token was detected (OpenCode, VS Code, Keychain, etc.)
- **Gemini Account Labels**: Shows `Gemini CLI (email)` when email is available, with fallback to `Gemini CLI #N`

### Usage History & Predictions
- **Daily Tracking**: View request counts and overage costs
- **EOM Prediction**: Estimates end-of-month totals using weighted averages
- **Add-on Cost Tracking**: Shows additional costs when exceeding limits

### Subscription Settings (Quota-based Providers Only)
- **Per-Provider Plans**: Configure your subscription tier for quota-based providers
- **Cost Tracking**: Accurate monthly cost calculation based on your plan
- **Orphaned Plan Cleanup**: Detect and reset stale subscription entries that no longer match accounts

### Convenience
- **Launch at Login**: Start automatically with macOS
- **Parallel Fetching**: All providers update simultaneously for speed
- **Auto Updates**: Seamless background updates via Sparkle framework

## Development

### Build from Source

```bash
# Clone the repository
git clone https://github.com/opgginc/opencode-bar.git
cd opencode-bar

# Build
xcodebuild -project CopilotMonitor/CopilotMonitor.xcodeproj \
  -scheme CopilotMonitor -configuration Debug build

# Open the app (auto-detect path)
open "$(xcodebuild -project CopilotMonitor/CopilotMonitor.xcodeproj -scheme CopilotMonitor -configuration Debug -showBuildSettings 2>/dev/null | sed -n 's/^[[:space:]]*BUILT_PRODUCTS_DIR = //p' | head -n 1)/OpenCode Bar.app"
```

**Requirements:**
- macOS 13.0+
- Xcode 15.0+ (for building from source)
- [OpenCode](https://opencode.ai) installed with authenticated providers

## Usage

### Menu Bar App

1. **Install OpenCode**: Make sure you have OpenCode installed and authenticated with your providers
2. **Launch the app**: Run OpenCode Bar
3. **View usage**: Click the menu bar icon to see all your provider usage
4. **GitHub Copilot** (optional): Automatically detected from multiple sources — OpenCode auth, Copilot CLI Keychain, VS Code/Cursor config files, and browser cookies (Chrome, Brave, Arc, Edge). Multiple accounts are deduplicated automatically.

### Command Line Interface (CLI)

OpenCode Bar includes a powerful CLI for querying provider usage programmatically.

#### Installation

```bash
# Option 1: Install via menu bar app
# Click "Install CLI" from the Settings menu

# Option 2: Manual installation
bash scripts/install-cli.sh

# Verify installation
opencodebar --help
```

#### Commands

```bash
# Show all providers and their usage (default command)
opencodebar status

# List all available providers
opencodebar list

# Get detailed info for a specific provider
opencodebar provider claude
opencodebar provider gemini_cli
opencodebar provider minimax_coding_plan

# Output as JSON (for scripting)
opencodebar status --json
opencodebar provider claude --json
opencodebar provider minimax_coding_plan --json
opencodebar list --json
```

#### Table Output Example

```bash
$ opencodebar status
Provider              Type             Usage       Key Metrics
─────────────────────────────────────────────────────────────────────────────────
Claude                Quota-based      77%         23/100 remaining
Codex                 Quota-based      0%          100/100 remaining
Copilot (user1)       Quota-based      45%         550/1000 remaining
Copilot (user2)       Quota-based      12%         880/1000 remaining
Gemini CLI (user1@gmail.com) Quota-based      0%          100% remaining
Gemini CLI (user2@company.com) Quota-based    15%         85% remaining
Kimi for Coding       Quota-based      26%         74/100 remaining
MiniMax Coding Plan   Quota-based      0%,0%      100/100 remaining
OpenCode Zen          Pay-as-you-go    -           $12.50 spent
OpenRouter            Pay-as-you-go    -           $37.42 spent
```

#### MiniMax Notes

- MiniMax Coding Plan is resolved from the OpenCode auth entry `minimax-coding-plan` in `auth.json`.
- OpenCode Bar uses the Coding Plan remains endpoint and converts it into used percentages for the menu bar app and CLI.
- MiniMax response fields `current_interval_usage_count` and `current_weekly_usage_count` behave as remaining counts despite their names, so OpenCode Bar calculates used percent as `total - remaining`.

#### JSON Output Example

```bash
$ opencodebar status --json
{
  "claude": {
    "type": "quota-based",
    "remaining": 23,
    "entitlement": 100,
    "usagePercentage": 77,
    "overagePermitted": false
  },
  "copilot": {
    "type": "quota-based",
    "remaining": 1430,
    "entitlement": 2000,
    "usagePercentage": 28,
    "overagePermitted": true,
    "accounts": [
      {
        "index": 0,
        "login": "user1",
        "authSource": "opencode",
        "remaining": 550,
        "entitlement": 1000,
        "usagePercentage": 45,
        "overagePermitted": true
      },
      {
        "index": 1,
        "login": "user2",
        "authSource": "copilot_cli_keychain",
        "remaining": 880,
        "entitlement": 1000,
        "usagePercentage": 12,
        "overagePermitted": true
      }
    ]
  },
  "gemini_cli": {
    "type": "quota-based",
    "remaining": 85,
    "entitlement": 100,
    "usagePercentage": 15,
    "overagePermitted": false,
    "accounts": [
      {
        "index": 0,
        "email": "user1@gmail.com",
        "accountId": "100663739661147150906",
        "remainingPercentage": 100,
        "modelBreakdown": {
          "gemini-2.5-pro": 100,
          "gemini-2.5-flash": 100
        }
      },
      {
        "index": 1,
        "email": "user2@company.com",
        "accountId": "109876543210987654321",
        "remainingPercentage": 85,
        "modelBreakdown": {
          "gemini-2.5-pro": 85,
          "gemini-2.5-flash": 90
        }
      }
    ]
  },
  "openrouter": {
    "type": "pay-as-you-go",
    "cost": 37.42
  }
}
```

#### Use Cases

- **Monitoring**: Integrate with monitoring systems to track API usage
- **Automation**: Build scripts that respond to quota thresholds
- **CI/CD**: Check provider quotas before running expensive operations
- **Reporting**: Generate usage reports for billing and analysis

#### Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | General error |
| 2 | Authentication failed |
| 3 | Network error |
| 4 | Invalid arguments |

### Menu Structure

```
─────────────────────────────
Pay-as-you-go: $37.61
  OpenRouter       $37.42    ▸
  OpenCode Zen     $0.19     ▸
─────────────────────────────
Quota Status: $219/m
  Copilot          0%        ▸
  Claude: 60%, 100%          ▸
  Codex            100%      ▸
  MiniMax Coding Plan 0%, 0% ▸
  Z.AI Coding Plan 99%       ▸
  Gemini CLI (user1@gmail.com) 100% ▸
─────────────────────────────
Predicted EOM: $451
─────────────────────────────
Refresh (⌘R)
Auto Refresh              ▸
Settings                  ▸
─────────────────────────────
Version 2.1.0
Quit (⌘Q)
```

#### Menu Group Titles

| Group | Format | Description |
|-------|--------|-------------|
| **Pay-as-you-go** | `Pay-as-you-go: $XX.XX` | Sum of all pay-as-you-go provider costs (OpenRouter + OpenCode Zen) |
| **Quota Status** | `Quota Status: $XXX/m` | Shows total monthly subscription cost if any quota-based providers have subscription settings configured. If no subscriptions are set, shows just "Quota Status". |

##### Status Bar Options

- **Menu Bar Display**: Choose one of `Total Cost`, `Icon Only`, or `Only Show`.
- **Critical Badge**: Toggle on/off to show or hide the critical-usage badge.
- **Show Provider Icon**: Toggle on/off to append the selected provider icon in the status bar.

> **Status Bar Icon Behavior**:
> The primary OpenCode Bar status icon always stays visible. Provider icons are rendered as an additional icon next to the primary icon (not a replacement).
>
> **Gemini Icon Sizing**:
> Gemini uses a slightly larger icon size than other providers in both menu rows and the status bar to match the official visual balance.

> **Note**: Subscription settings are only available for quota-based providers. Pay-as-you-go providers do not have subscription options since they charge based on actual usage.
>
> **Terminology**:
> `Status Bar Percent` means the single representative percentage shown in the macOS top status bar text.
> `Dropdown Detail Percents` means the multi-window percentages shown in provider rows inside the opened dropdown menu.
>
> **Status Bar Percent Rule**: `Status Bar Percent` uses one fixed priority:
> `Weekly` → `Monthly` → `Daily` → `Hourly` → fallback aggregate.
> If multiple values exist in the same priority window, the highest value is shown (for example, Claude weekly picks max of 7d/Sonnet/Opus).
> In `Recent Quota Change Only`, provider selection is based on change, but the shown percentage is the provider's current priority-based usage.
>
> **Dropdown Detail Percents Rule**: top-level menu rows keep multi-window percentages when available.

## How It Works

1. **Token Discovery**: Reads authentication tokens from OpenCode's `auth.json` (with multi-path fallback), including plugin-managed OpenAI metadata
2. **Multi-Source Account Discovery**: For providers like ChatGPT and GitHub Copilot, discovers accounts from multiple sources (OpenCode auth, OpenCode plugin files, CLI/Keychain/config stores, browser cookies) and deduplicates them by stable account metadata
3. **Parallel Fetching**: Queries all provider APIs simultaneously using TaskGroup
4. **Smart Caching**: Falls back to cached data on network errors
5. **Graceful Degradation**: Shows available providers even if some fail

MiniMax Coding Plan uses `https://api.minimax.io/v1/api/openplatform/coding_plan/remains` and is displayed with explicit 5h used and weekly used windows in the provider submenu.

### Privacy & Security

- **Local Only**: All data stays on your machine
- **No Third-party Servers**: Direct communication with provider APIs
- **Read-only Access**: Uses existing OpenCode tokens (no additional permissions)
- **Browser Cookie Access**: GitHub Copilot reads session cookies from your default browser (read-only, no passwords stored)

## Troubleshooting

### "No providers found" or auth.json not detected
The app searches for `auth.json` in these locations (in order):
1. `$XDG_DATA_HOME/opencode/auth.json` (if XDG_DATA_HOME is set)
2. `~/.local/share/opencode/auth.json` (default)
3. `~/Library/Application Support/opencode/auth.json` (macOS fallback)

For ChatGPT/Codex multi-account setups, the app also searches:
1. `~/.opencode/auth/openai.json`
2. `~/.opencode/openai-codex-accounts.json`
3. `~/.opencode/projects/*/openai-codex-accounts.json`

If `oc-chatgpt-multi-auth` is installed and OpenCode sets `provider.openai.options.baseURL` to a localhost proxy, OpenCode Bar still queries the direct ChatGPT usage endpoint by default. Only the explicit `opencode-bar.codex.usageURL` override changes the usage endpoint.

### GitHub Copilot not showing
GitHub Copilot accounts are discovered from multiple sources (in priority order):
1. **OpenCode auth** — `copilot` entry in OpenCode `auth.json`
2. **Copilot CLI Keychain** — macOS Keychain entries for `github.com`
3. **VS Code / Cursor** — `~/.config/github-copilot/hosts.json` and `apps.json`
4. **Browser Cookies** — Chrome, Brave, Arc, Edge session cookies

If Copilot still doesn't appear:
- Verify at least one source has valid credentials (`opencodebar provider copilot` for details)
- For browser cookies: make sure you're signed into GitHub in a supported browser
- Accounts from different sources with the same login are automatically merged

### OpenCode CLI commands failing
The app dynamically searches for the `opencode` binary in:
- Current PATH (`which opencode`)
- Login shell PATH
- Common install locations: `~/.opencode/bin/opencode`, `/usr/local/bin/opencode`, etc.

## Contributing

Contributions are welcome! Please submit a Pull Request.

### Development Setup

1. Fork the Project
2. Create your Feature Branch (`git checkout -b feature/AmazingFeature`)
3. **Setup Git Hooks** (run once after clone):
   ```bash
   make setup
   ```
   This configures pre-commit hooks for:
   - **SwiftLint**: Checks Swift code style on staged `.swift` files
   - **action-validator**: Validates GitHub Actions workflow files
4. Make your Changes
5. Commit your Changes (`git commit -m 'Add some AmazingFeature'`)
   - Pre-commit hooks will automatically check your code
   - Fix any violations or use `git commit --no-verify` to bypass (not recommended)
6. Push to the Branch (`git push origin feature/AmazingFeature`)
7. Open a Pull Request

### Code Quality

This project uses SwiftLint and action-validator to maintain code quality:

- **Pre-commit Hook**: Runs on `git commit` (setup via `make setup`)
  - SwiftLint for `.swift` files
  - action-validator for `.github/workflows/*.yml` files
- **GitHub Actions**: Runs on all pushes and pull requests
- **Manual Check**: `make lint` (or `make lint-swift`, `make lint-actions`)

## License

MIT License - See [LICENSE](LICENSE) file for details.

## Related

- [OpenCode](https://opencode.ai) - The AI coding assistant that powers this monitor
- [GitHub Copilot](https://github.com/features/copilot)

## Credits

- [OP.GG](https://op.gg)
- [Sangrak Choi](https://kargn.as)

---

<p align="center">
  Made with tiredness for AI power users
</p>
