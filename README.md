# OpenCode Usage Monitor

<p align="center">
  <img src="docs/screenshot2.png" alt="OpenCode Usage Monitor Screenshot" width="40%">
  <img src="docs/screenshot3.png" alt="OpenCode Usage Monitor Screenshot" width="40%">
</p>

<p align="center">
  <strong>Automatically monitor all your AI provider usage from OpenCode in real-time from the macOS menu bar.</strong>
</p>

<p align="center">
  <a href="https://github.com/kargnas/copilot-usage-monitor/releases/latest">
    <img src="https://img.shields.io/github/v/release/kargnas/copilot-usage-monitor?style=flat-square" alt="Release">
  </a>
  <a href="https://github.com/kargnas/copilot-usage-monitor/blob/main/LICENSE">
    <img src="https://img.shields.io/github/license/kargnas/copilot-usage-monitor?style=flat-square" alt="License">
  </a>
  <img src="https://img.shields.io/badge/platform-macOS%2013%2B-blue?style=flat-square" alt="Platform">
  <img src="https://img.shields.io/badge/swift-5.9-orange?style=flat-square" alt="Swift">
</p>

---

## Overview

**OpenCode Usage Monitor** automatically detects and monitors all AI providers registered in your [OpenCode](https://opencode.ai) configuration. No manual setup required - just install and see your usage across all providers in one unified dashboard.

### Supported Providers (Auto-detected from OpenCode)

| Provider | Type | Key Metrics |
|----------|------|-------------|
| **Claude** | Quota-based | 5h/7d usage windows, Sonnet/Opus breakdown |
| **Codex** | Quota-based | Primary/Secondary quotas, plan type |
| **Gemini CLI** | Quota-based | Per-model quotas, multi-account support |
| **OpenRouter** | Pay-as-you-go | Credits balance, daily/weekly/monthly cost |
| **OpenCode Zen** | Pay-as-you-go | Daily history (30 days), model breakdown |
| **Antigravity** | Pay-as-you-go | Local language server monitoring |
| **GitHub Copilot** | Quota-based | Daily history, overage tracking, EOM prediction |

## Features

### Automatic Provider Detection
- **Zero Configuration**: Reads your `~/.local/share/opencode/auth.json` automatically
- **Dynamic Updates**: New providers appear as you add them to OpenCode
- **Smart Categorization**: Pay-as-you-go vs Quota-based providers displayed separately

### Real-time Monitoring
- **Menu Bar Dashboard**: View all provider usage at a glance
- **Visual Indicators**: Color-coded progress (green → yellow → orange → red)
- **Quota Alerts**: Warning icons when remaining quota < 20%
- **Detailed Submenus**: Click any provider for in-depth metrics

### Usage History & Predictions (Copilot)
- **Daily Tracking**: View request counts and overage costs
- **EOM Prediction**: Estimates end-of-month totals using weighted averages
- **Add-on Cost Tracking**: Shows additional costs when exceeding limits

### Convenience
- **Auto Refresh**: Configurable intervals (10 seconds to 30 minutes)
- **Launch at Login**: Start automatically with macOS
- **Parallel Fetching**: All providers update simultaneously for speed

## Installation

### Download (Recommended)

Download the latest `.dmg` file from the [**Releases**](https://github.com/kargnas/copilot-usage-monitor/releases/latest) page.

> **Note**: If you see a "App is damaged" error, run this command in Terminal:
> ```bash
> xattr -cr "/Applications/CopilotMonitor.app"
> ```

### Build from Source

```bash
# Clone the repository
git clone https://github.com/kargnas/copilot-usage-monitor.git
cd copilot-usage-monitor

# Build and run
xcodebuild -project CopilotMonitor/CopilotMonitor.xcodeproj \
  -scheme CopilotMonitor -configuration Debug build

# Open the app
open ~/Library/Developer/Xcode/DerivedData/CopilotMonitor-*/Build/Products/Debug/*.app
```

**Requirements:**
- macOS 13.0+
- Xcode 15.0+ (for building from source)
- [OpenCode](https://opencode.ai) installed with authenticated providers

## Usage

1. **Install OpenCode**: Make sure you have OpenCode installed and authenticated with your providers
2. **Launch the app**: Run OpenCode Usage Monitor
3. **View usage**: Click the menu bar icon to see all your provider usage
4. **GitHub Copilot** (optional): Click "Sign In" to add Copilot monitoring via GitHub OAuth

### Menu Structure

```
─────────────────────────────
Pay-as-you-go
  OpenRouter       $37.42    ▸
  OpenCode Zen     $0.19     ▸
─────────────────────────────
Quota Status
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
Version 2.0.0
Quit (⌘Q)
```

## How It Works

1. **Token Discovery**: Reads authentication tokens from OpenCode's `auth.json`
2. **Parallel Fetching**: Queries all provider APIs simultaneously
3. **Smart Caching**: Falls back to cached data on network errors
4. **Graceful Degradation**: Shows available providers even if some fail

### Privacy & Security

- **Local Only**: All data stays on your machine
- **No Third-party Servers**: Direct communication with provider APIs
- **Read-only Access**: Uses existing OpenCode tokens (no additional permissions)
- **Secure Storage**: GitHub Copilot uses OAuth session without storing passwords

## Contributing

Contributions are welcome! Please submit a Pull Request.

1. Fork the Project
2. Create your Feature Branch (`git checkout -b feature/AmazingFeature`)
3. Commit your Changes (`git commit -m 'Add some AmazingFeature'`)
4. Push to the Branch (`git push origin feature/AmazingFeature`)
5. Open a Pull Request

## License

MIT License - See [LICENSE](LICENSE) file for details.

## Related

- [OpenCode](https://opencode.ai) - The AI coding assistant that powers this monitor
- [GitHub Copilot](https://github.com/features/copilot)

---

<p align="center">
  Made with tiredness for AI power users
</p>
