# OpenCode Bar

<p align="center">
  <img src="docs/screenshot-subscription.png" alt="OpenCode Bar Screenshot" width="40%">
  <img src="docs/screenshot3.png" alt="OpenCode Bar Screenshot" width="40%">
</p>

<p align="center">
  <strong>Automatically monitor all your AI provider usage from OpenCode in real-time from the macOS menu bar.</strong>
</p>

<p align="center">
  <a href="https://github.com/kargnas/opencode-bar/releases/latest">
    <img src="https://img.shields.io/github/v/release/kargnas/opencode-bar?style=flat-square" alt="Release">
  </a>
  <a href="https://github.com/kargnas/opencode-bar/blob/main/LICENSE">
    <img src="https://img.shields.io/github/license/kargnas/opencode-bar?style=flat-square" alt="License">
  </a>
  <img src="https://img.shields.io/badge/platform-macOS%2013%2B-blue?style=flat-square" alt="Platform">
  <img src="https://img.shields.io/badge/swift-5.9-orange?style=flat-square" alt="Swift">
</p>

---

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
| **Gemini CLI** | Quota-based | Per-model quotas, multi-account support |
| **Kimi for Coding (Kimi K2.5)** | Quota-based | Usage limits, membership level, reset time |
| **Antigravity** | Quota-based | Local language server monitoring |
| **GitHub Copilot** | Quota-based | Daily history, overage tracking |

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

### Usage History & Predictions
- **Daily Tracking**: View request counts and overage costs
- **EOM Prediction**: Estimates end-of-month totals using weighted averages
- **Add-on Cost Tracking**: Shows additional costs when exceeding limits

### Subscription Settings (Quota-based Providers Only)
- **Per-Provider Plans**: Configure your subscription tier for quota-based providers
- **Cost Tracking**: Accurate monthly cost calculation based on your plan

### Convenience
- **Launch at Login**: Start automatically with macOS
- **Parallel Fetching**: All providers update simultaneously for speed
- **Auto Updates**: Seamless background updates via Sparkle framework

## Installation

### Download (Recommended)

Download the latest `.dmg` file from the [**Releases**](https://github.com/kargnas/opencode-bar/releases/latest) page.

> **Note**: If you see a "App is damaged" error, run this command in Terminal:
> ```bash
> xattr -cr "/Applications/OpenCode Bar.app"
> ```

### Build from Source

```bash
# Clone the repository
git clone https://github.com/kargnas/opencode-bar.git
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
4. **GitHub Copilot** (optional): Automatically detected via browser cookies (Chrome, Brave, Arc, Edge supported)

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

# Output as JSON (for scripting)
opencodebar status --json
opencodebar provider claude --json
opencodebar list --json
```

#### Table Output Example

```bash
$ opencodebar status
Provider              Type             Usage       Key Metrics
─────────────────────────────────────────────────────────────────────────────────
Claude                Quota-based      77%         23/100 remaining
Codex                 Quota-based      0%          100/100 remaining
Gemini (#1)           Quota-based      0%          100% remaining (user1@gmail.com)
Gemini (#2)           Quota-based      15%         85% remaining (user2@company.com)
Kimi for Coding       Quota-based      26%         74/100 remaining
OpenCode Zen          Pay-as-you-go    -           $12.50 spent
OpenRouter            Pay-as-you-go    -           $37.42 spent
```

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
        "remainingPercentage": 100,
        "modelBreakdown": {
          "gemini-2.5-pro": 100,
          "gemini-2.5-flash": 100
        }
      },
      {
        "index": 1,
        "email": "user2@company.com",
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
  Claude           60%       ▸
  Codex            100%      ▸
  Gemini CLI (#1)  100%      ▸
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

> **Note**: Subscription settings are only available for quota-based providers. Pay-as-you-go providers do not have subscription options since they charge based on actual usage.

## How It Works

1. **Token Discovery**: Reads authentication tokens from OpenCode's `auth.json` (with multi-path fallback)
2. **Cookie Detection**: Finds GitHub Copilot sessions from Chrome, Brave, Arc, or Edge (with profile support)
3. **Parallel Fetching**: Queries all provider APIs simultaneously
4. **Smart Caching**: Falls back to cached data on network errors
5. **Graceful Degradation**: Shows available providers even if some fail

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

### GitHub Copilot not showing
- Make sure you're signed into GitHub in a supported browser (Chrome, Brave, Arc, or Edge)
- The app reads session cookies from browser profiles—no manual login required
- Check that your browser has active GitHub cookies (try visiting github.com)

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
3. **Setup Git Hooks** (automated linting before commits):
   ```bash
   ./scripts/setup-git-hooks.sh
   ```
4. Make your Changes
5. Commit your Changes (`git commit -m 'Add some AmazingFeature'`)
   - SwiftLint will automatically check your code before commit
   - Fix any violations or use `git commit --no-verify` to bypass (not recommended)
6. Push to the Branch (`git push origin feature/AmazingFeature`)
7. Open a Pull Request

### Code Quality

This project uses SwiftLint to maintain code quality. All Swift files are automatically checked:

- **Pre-commit Hook**: Runs on `git commit` (install via `./scripts/setup-git-hooks.sh`)
- **GitHub Actions**: Runs on all pushes and pull requests
- **Manual Check**: Run `swiftlint lint CopilotMonitor/CopilotMonitor` anytime

## License

MIT License - See [LICENSE](LICENSE) file for details.

## Related

- [OpenCode](https://opencode.ai) - The AI coding assistant that powers this monitor
- [GitHub Copilot](https://github.com/features/copilot)

---

<p align="center">
  Made with tiredness for AI power users
</p>
